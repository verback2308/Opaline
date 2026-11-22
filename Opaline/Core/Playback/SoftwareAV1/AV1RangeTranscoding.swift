import AVFoundation

/// Byte-range delivery of a software-AV1 video track. AVPlayer cannot read
/// AV1 here and will not take media segments from a resource loader, so the
/// whole presentation moves onto a loopback server: playlists and the
/// transcoded video from there, audio still fetched straight from its URLs.
/// Mixing a custom-scheme playlist with loopback segments fails outright
/// (-16170); an all-HTTP presentation is what SABR already plays.
final class AV1RangeTranscoding {
    private let server: LocalMediaServer
    private let session: AV1TranscodeSession

    private init?(
        input: HLSPlaybackBuilder.BuildInput,
        segments: [SidxSegment],
        playlists: Playlists
    ) {
        let session = AV1TranscodeSession(
            plan: AV1ChunkPlan(segments: segments),
            format: (height: input.videoFormat.height ?? 0, fps: input.videoFormat.fps ?? 30)
        ) { index, completion in
            HLSPlaybackBuilder.fetchRangeData(
                request: Self.range(of: index, input: input, segments: segments),
                completion: completion
            )
        }
        let handler: LocalMediaServer.Handler = { path, completion in
            Self.serve(path, session: session, playlists: playlists, completion: completion)
        }
        guard let server = LocalMediaServer(handler: handler) else {
            return nil
        }
        self.server = server
        self.session = session
    }

    /// Starts the server and hands back an item that plays from it. Audio-only
    /// playback has no video to transcode and keeps the item as built.
    static func attach(
        to result: HLSPlaybackBuilder.Result,
        input: HLSPlaybackBuilder.BuildInput,
        segments: [SidxSegment],
        completion: @escaping (HLSPlaybackBuilder.Result?) -> Void
    ) {
        guard !AudioOnlyMode.isEnabled else {
            completion(result)
            return
        }
        let playlists = Playlists(input: input, segments: segments, loader: result.loader)
        guard let transcoding = Self(input: input, segments: segments, playlists: playlists) else {
            completion(nil)
            return
        }
        // Set the transcoder up before handing out the item — a stream it
        // cannot take fails here, where the chain can still fall back — while
        // the server starts alongside.
        let group = DispatchGroup()
        var codecs: String?
        var base: URL?
        group.enter()
        transcoding.session.codecs {
            codecs = $0
            group.leave()
        }
        group.enter()
        transcoding.server.start {
            base = $0
            group.leave()
        }
        group.notify(queue: .main) {
            guard codecs != nil, let base else {
                completion(nil)
                return
            }
            transcoding.start(at: base, result: result, input: input, completion: completion)
        }
    }

    /// The init range runs through the sidx, so the reader sees the moov;
    /// media segments follow the index back to back.
    private static func range(
        of index: Int?,
        input: HLSPlaybackBuilder.BuildInput,
        segments: [SidxSegment]
    ) -> HLSPlaybackBuilder.RangeRequest {
        let dataStart = Int64(input.videoFormat.indexRangeEnd + 1)
        guard let index, index < segments.count else {
            return HLSPlaybackBuilder.RangeRequest(
                url: input.videoURL,
                start: 0,
                end: dataStart - 1,
                headers: input.headers
            )
        }
        let segment = segments[index]
        return HLSPlaybackBuilder.RangeRequest(
            url: input.videoURL,
            start: dataStart + segment.offset,
            end: dataStart + segment.offset + segment.size - 1,
            headers: input.headers
        )
    }

    private static func serve(
        _ path: String,
        session: AV1TranscodeSession,
        playlists: Playlists,
        completion: @escaping (Data?, String) -> Void
    ) {
        let parts = path.split(separator: "/").map(String.init)
        let playlistType = "application/vnd.apple.mpegurl"
        if parts == ["master.m3u8"] {
            session.codecs { codecs in
                completion(codecs.map { Data(playlists.main(videoCodecs: $0).utf8) }, playlistType)
            }
            return
        }
        if parts.count == 1, let playlist = playlists.media[parts[0]] {
            completion(playlist, playlistType)
            return
        }
        guard parts.count == 2, parts[0] == "av1" else {
            completion(nil, "")
            return
        }
        let respond: AV1TranscodeSession.Completion = { completion($0, "video/mp4") }
        if parts[1] == "init" {
            session.initSegment(completion: respond)
        } else if let id = AV1ChunkID(name: parts[1]) {
            session.chunk(id, completion: respond)
        } else {
            completion(nil, "")
        }
    }

    private func start(
        at base: URL,
        result: HLSPlaybackBuilder.Result,
        input: HLSPlaybackBuilder.BuildInput,
        completion: @escaping (HLSPlaybackBuilder.Result?) -> Void
    ) {
        result.loader.keepAlive = self
        AppLog.hls("av1: transcoding \(input.videoFormat.itag) through \(base.absoluteString)")
        let asset = AVURLAsset(
            url: base.appendingPathComponent("master.m3u8"),
            options: ["AVURLAssetHTTPHeaderFieldsKey": input.headers]
        )
        let item = AVPlayerItem(asset: asset)
        PlaybackBufferPolicy.configure(item: item)
        completion(HLSPlaybackBuilder.Result(playerItem: item, loader: result.loader))
    }
}

/// The presentation's playlists, all with URIs relative to the server. The
/// main one waits for the transcoder: its CODECS has to name the encoder's
/// actual profile and level.
private struct Playlists {
    let input: HLSPlaybackBuilder.BuildInput
    let media: [String: Data]

    init(input: HLSPlaybackBuilder.BuildInput, segments: [SidxSegment], loader: HLSPlaylistLoader) {
        self.input = input
        let video = AV1ChunkPlan(segments: segments).playlist(base: "av1", startAt: input.startAt)
        media = [
            "video.m3u8": Data(video.utf8),
            "audio.m3u8": loader.playlist(at: "audio.m3u8") ?? Data()
        ]
    }

    func main(videoCodecs: String) -> String {
        let format = input.videoFormat
        let peak = AV1SegmentTranscoder.peakBitrate(
            height: format.height ?? 0,
            fps: format.fps ?? 30
        )
        return HLSGenerator.mainPlaylist(
            bandwidth: peak + input.audioFormat.bitrate,
            codecs: "\(videoCodecs),\(input.audioFormat.codecs)",
            resolution: "\(format.width ?? 1_280)x\(format.height ?? 720)",
            uris: HLSGenerator.PlaylistURIs(video: "video.m3u8", audio: "audio.m3u8")
        )
    }
}
