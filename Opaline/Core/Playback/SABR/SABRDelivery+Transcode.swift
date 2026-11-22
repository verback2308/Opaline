import Foundation

// MARK: - Software AV1 over SABR

extension SABRDelivery.Route {
    /// This route with a transcoder for its video track when that track is
    /// AV1 the device cannot decode — the source segments come through the
    /// same SABR requests AVPlayer's would have made.
    func withTranscoding() -> Self {
        guard let video = tracks.first, video.path == "video",
              AV1Support.needsTranscode(video.format) else {
            return self
        }
        var routed = self
        let source = self
        routed.transcode = AV1TranscodeSession(
            plan: AV1ChunkPlan(segments: video.segments),
            format: (height: video.format.height ?? 0, fps: video.format.fps ?? 30),
            initSource: video.initData.isEmpty ? nil : video.initData
        ) { index, completion in
            let name = index.map(String.init) ?? "init"
            guard let request = SABRDelivery.segmentRequest(name, of: video, route: source) else {
                completion(nil)
                return
            }
            source.fetcher.fetch(request) { completion(try? $0.get()) }
        }
        AppLog.hls("av1: transcoding \(video.format.itag) over SABR")
        return routed
    }
}

extension SABRDelivery {
    /// A media playlist — the video one cut into chunks when it is transcoded.
    static func playlist(named name: String, route: Route) -> Data? {
        guard name == "video", let transcode = route.transcode else {
            return mediaPlaylist(named: name, route: route)
        }
        let base = "/g\(route.generation)/s/video"
        return Data(transcode.plan.playlist(base: base, startAt: route.startAt).utf8)
    }

    /// The main playlist. With a transcoded video track it waits for the
    /// transcoder: CODECS must name what the encoder really produces.
    static func serveMain(route: Route, completion: @escaping (Data?, String) -> Void) {
        let playlistType = "application/vnd.apple.mpegurl"
        guard let transcode = route.transcode else {
            completion(Data(mainPlaylist(route: route).utf8), playlistType)
            return
        }
        transcode.codecs { codecs in
            let video = codecs.map { codecs in
                TranscodedVideo(
                    codecs: codecs,
                    peak: AV1SegmentTranscoder.peakBitrate(
                        height: route.tracks.first?.format.height ?? 0,
                        fps: route.tracks.first?.format.fps ?? 30
                    )
                )
            }
            let playlist = video.map { mainPlaylist(route: route, transcoded: $0) }
            completion(playlist.map { Data($0.utf8) }, playlistType)
        }
    }

    static func serveTranscoded(
        _ name: String,
        session: AV1TranscodeSession,
        completion: @escaping (Data?, String) -> Void
    ) {
        let respond: AV1TranscodeSession.Completion = { completion($0, "video/mp4") }
        if name == "init" {
            session.initSegment(completion: respond)
        } else if let id = AV1ChunkID(name: name) {
            session.chunk(id, completion: respond)
        } else {
            completion(nil, "")
        }
    }
}

extension SABRDelivery {
    /// The server, once the route's transcoder — if it has one — is set up:
    /// a stream it cannot take fails here, before the item is handed out,
    /// where the chain can still fall back to another way of playing.
    func withTranscoderAndServer(_ completion: @escaping (URL?) -> Void) {
        guard let transcode = route?.transcode else {
            withServer(completion)
            return
        }
        transcode.codecs { codecs in
            Self.attachQueue.async {
                guard codecs != nil else {
                    AppLog.hls("av1: transcoder could not be set up over SABR")
                    completion(nil)
                    return
                }
                self.withServer(completion)
            }
        }
    }
}

/// What a transcoded video track is, for its main playlist entry.
struct TranscodedVideo {
    let codecs: String
    let peak: Int
}
