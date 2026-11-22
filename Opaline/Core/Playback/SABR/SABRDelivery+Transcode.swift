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
            segmentCount: video.segments.count,
            fps: video.format.fps ?? 30
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
    /// The main playlist. With a transcoded video track it waits for the
    /// transcoder: CODECS must name what the encoder really produces.
    static func serveMain(route: Route, completion: @escaping (Data?, String) -> Void) {
        let playlistType = "application/vnd.apple.mpegurl"
        guard let transcode = route.transcode else {
            completion(Data(mainPlaylist(route: route).utf8), playlistType)
            return
        }
        transcode.codecs { codecs in
            let playlist = codecs.map { mainPlaylist(route: route, videoCodecs: $0) }
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
        } else if let index = Int(name) {
            session.segment(index, completion: respond)
        } else {
            completion(nil, "")
        }
    }
}
