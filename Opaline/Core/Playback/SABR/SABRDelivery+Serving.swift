import AVFoundation
import Foundation

// MARK: - Serving the streams to AVPlayer

extension SABRDelivery {
    /// What the server currently serves: one session and its two tracks.
    struct Route {
        let generation: Int
        let tracks: [Track]
        let fetcher: SABRFetcher
        /// Where playback should pick up, for `EXT-X-START`.
        let startAt: Double?
        /// Set when the video track is software AV1 (see AV1Support).
        var transcode: AV1TranscodeSession?
    }

    /// The single writer for the routing state the loopback server reads.
    static let attachQueue = DispatchQueue(label: "com.ytvlite.sabr-attach")

    static func ms(from: Date, to: Date) -> Int {
        Int(to.timeIntervalSince(from) * 1_000)
    }

    /// Routes one HTTP path to the bytes behind it.
    ///
    /// Paths are `/g<n>/master.m3u8`, `/g<n>/<track>.m3u8` and
    /// `/g<n>/s/<track>/<index>` (or `.../init`). The generation is what makes
    /// a quality switch work on one server: AVPlayer caches playlists per URL,
    /// so reusing paths would hand it the previous playlist. Requests for a
    /// retired generation are refused — that item is gone.
    static func route(
        path: String,
        route: Route?,
        completion: @escaping (Data?, String) -> Void
    ) {
        let parts = path.split(separator: "/").map(String.init)
        guard let route, parts.first == "g\(route.generation)" else {
            completion(nil, "")
            return
        }
        let rest = Array(parts.dropFirst())
        let playlistType = "application/vnd.apple.mpegurl"
        if rest == ["master.m3u8"] {
            serveMain(route: route, completion: completion)
            return
        }
        if rest.count == 1, rest[0].hasSuffix(".m3u8") {
            let name = String(rest[0].dropLast(5))
            completion(playlist(named: name, route: route), playlistType)
            return
        }
        guard rest.count == 3, rest[0] == "s",
              let track = route.tracks.first(where: { $0.path == rest[1] }) else {
            completion(nil, "")
            return
        }
        if track.path == "video", let transcode = route.transcode {
            serveTranscoded(rest[2], session: transcode, completion: completion)
            return
        }
        serveSegment(rest[2], of: track, route: route, completion: completion)
    }

    /// One track's playlist, or nil when the name is not one of ours.
    static func mediaPlaylist(named name: String, route: Route) -> Data? {
        guard let track = route.tracks.first(where: { $0.path == name }) else {
            return nil
        }
        return Data(HLSGenerator.segmentedPlaylist(
            base: "/g\(route.generation)/s/\(track.path)",
            segments: track.segments,
            startAt: route.startAt
        ).utf8)
    }

    /// Main playlist pointing at the two media playlists.
    static func mainPlaylist(route: Route, videoCodecs: String? = nil) -> String {
        guard route.tracks.count == 2,
              let video = route.tracks.first,
              let audio = route.tracks.last else {
            return ""
        }
        let audioPeak = HLSGenerator.peakBitrate(audio.segments, fallback: audio.format.bitrate)
        let videoPeak = HLSGenerator.peakBitrate(video.segments, fallback: video.format.bitrate)
        return HLSGenerator.mainPlaylist(
            bandwidth: videoPeak + audioPeak,
            codecs: "\(videoCodecs ?? video.format.codecs),\(audio.format.codecs)",
            resolution: "\(video.format.width ?? 1_280)x\(video.format.height ?? 720)",
            uris: HLSGenerator.PlaylistURIs(
                video: "/g\(route.generation)/\(video.path).m3u8",
                audio: "/g\(route.generation)/\(audio.path).m3u8"
            )
        )
    }

    private static func serveSegment(
        _ name: String,
        of track: Track,
        route: Route,
        completion: @escaping (Data?, String) -> Void
    ) {
        guard let request = segmentRequest(name, of: track, route: route) else {
            completion(nil, "")
            return
        }
        route.fetcher.fetch(request) { result in
            switch result {
            case .success(let data):
                completion(data, "video/mp4")
            case .failure(let error):
                AppLog.hls("segment \(track.path)/\(name) failed: \(error.localizedDescription)")
                completion(nil, "")
            }
        }
    }

    /// Maps one playlist entry onto the segment the server knows: SABR counts
    /// segments from 1, and the time it is asked to stream from is where that
    /// segment starts.
    static func segmentRequest(
        _ name: String,
        of track: Track,
        route: Route
    ) -> SABRSegmentRequest? {
        let other = route.tracks
            .first { $0.format.itag != track.format.itag }
            .map { SABRDelivery.formatInfo($0.format) }
        guard let other else {
            return nil
        }
        let format = SABRDelivery.formatInfo(track.format)
        if name == "init" {
            // Everything before the first media byte: ftyp, moov and sidx.
            return SABRSegmentRequest(
                format: format,
                other: other,
                sequence: 1,
                timeMs: 0,
                initRange: track.format.indexRangeEnd + 1
            )
        }
        guard let index = Int(name), index < track.segments.count else {
            return nil
        }
        return SABRSegmentRequest(
            format: format,
            other: other,
            sequence: index + 1,
            timeMs: startMs(of: index, in: track),
            initRange: nil
        )
    }

    /// Where a segment starts on the timeline, from the sidx durations.
    static func startMs(of index: Int, in track: Track) -> Int {
        let elapsed = track.segments.prefix(index).reduce(0.0) { $0 + $1.duration }
        return Int(elapsed * 1_000)
    }

    /// Byte offset of a segment: the media data starts after the index, and
    /// every segment before it takes up its own size.
    static func segmentOffset(_ index: Int, in track: Track) -> Int64 {
        var offset = Int64(track.format.indexRangeEnd + 1)
        for segment in track.segments.prefix(index) {
            offset += segment.size
        }
        return offset
    }

    /// Where a byte offset falls on the timeline, so a seek can restart the
    /// session at that point rather than streaming forward to it.
    static func timeMs(at offset: Int64, in track: Track) -> Int {
        var position = Int64(track.format.indexRangeEnd + 1)
        var elapsed = 0.0
        for segment in track.segments {
            if offset < position + segment.size {
                return Int(elapsed * 1_000)
            }
            position += segment.size
            elapsed += segment.duration
        }
        return Int(elapsed * 1_000)
    }

    /// Pairs each format with its segment index, taking the formats the
    /// session actually runs rather than the response's defaults — a quality
    /// switch changes the video, a dub changes the audio, and building
    /// playlists from the defaults meant neither ever took effect.
    static func tracks(
        inits: [Int: Data],
        video: DashFormatInfo,
        audio: DashFormatInfo
    ) -> [Track]? {
        guard let videoInit = inits[video.itag],
              let audioInit = inits[audio.itag],
              let videoSegments = HLSGenerator.parseSidx(data: videoInit),
              let audioSegments = HLSGenerator.parseSidx(data: audioInit) else {
            return nil
        }
        return [
            Track(format: video, segments: videoSegments, path: "video"),
            Track(format: audio, segments: audioSegments, path: "audio")
        ]
    }

    /// Points the server at a new session and hands AVPlayer its playlist URL.
    ///
    /// One server outlives the sessions it serves: a quality switch swaps what
    /// it routes to instead of starting another listener. Starting a listener
    /// per switch leaked a socket set each time, and once enough had leaked new
    /// listeners stopped coming up at all — which showed up as quality
    /// switching doing nothing.
    func buildPlayback(
        _ request: DeliveryRequest,
        fetcher: SABRFetcher,
        inits: [Int: Data],
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        let info = request.info
        let started = Date()
        guard let tracks = Self.tracks(
            inits: inits, video: request.video, audio: request.audio
        ) else {
            completion(.failure(SABRError.noInitSegment))
            return
        }
        let parsed = Date()
        // Everything below touches state the server reads: the generation
        // counter, the server handle and its base URL. One serial queue keeps
        // a single writer — main used to, but the watch screen is building
        // comments and thumbnails at exactly this moment and the first frame
        // ended up queued behind it.
        Self.attachQueue.async {
            AppLog.hls(
                "sabr build: sidx \(Self.ms(from: started, to: parsed))ms,"
                    + " attach after \(Self.ms(from: parsed, to: Date()))ms"
            )
            self.attach(tracks: tracks, fetcher: fetcher, info: info, completion: completion)
        }
    }

    private func attach(
        tracks: [Track],
        fetcher: SABRFetcher,
        info: DirectPlaybackInfo,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        generation += 1
        // A quality switch replaces the fetcher behind the same server; the
        // one being replaced has nobody left to serve.
        route?.fetcher.stop()
        route = Route(
            generation: generation,
            tracks: tracks,
            fetcher: fetcher,
            startAt: pendingStartAt
        ).withTranscoding()
        pendingStartAt = nil
        let path = "g\(generation)/master.m3u8"
        withServer { base in
            guard let base else {
                completion(.failure(SABRError.server("local server did not come up")))
                return
            }
            let item = AVPlayerItem(asset: AVURLAsset(url: base.appendingPathComponent(path)))
            PlaybackBufferPolicy.configure(item: item)
            completion(.success(PreparedPlayback(
                item: item,
                captions: info.captionTracks,
                duration: info.duration,
                startsAt: self.route?.startAt
            )))
        }
    }

    /// The single server for this source, started on first use.
    private func withServer(_ completion: @escaping (URL?) -> Void) {
        if let base = serverBase {
            completion(base)
            return
        }
        let server = LocalMediaServer { [weak self] path, done in
            Self.route(path: path, route: self?.route, completion: done)
        }
        guard let server else {
            completion(nil)
            return
        }
        self.server = server
        server.start { [weak self] base in
            Self.attachQueue.async {
                self?.serverBase = base
                completion(base)
            }
        }
    }
}
