import Foundation

/// Apple Vision Pro's client, played anonymously.
///
/// The one anonymous client googlevideo still serves past the first minute of
/// a video: measured 2026-08-18 against android_vr, android and ios, all of
/// which stop between 59904 ms and 69888 ms while this one plays through
/// (Opaline#76). Its formats carry URLs, so it can be fetched either way —
/// byte ranges or SABR.
struct VisionOSClient: PlaybackClient {
    let name = "VISIONOS"
    let version = "1.02"
    let headerName = "101"
    let userAgent = UserAgent.visionOS
    let playerURL = "\(InnertubeEndpoint.player)?prettyPrint=false"
    let authorization = PlaybackAuthorization.anonymous
    /// The jar holds whatever else has been on the wire; a session-bound URL
    /// is not what an anonymous client can play.
    let sendsCookies = false
    let listsAudioTracks = true

    var innertubeContext: [String: Any] { InnertubeContexts.visionOS }

    func sabrClientInfo() -> Data {
        var info = Protobuf.string(12, "Apple")
        info += Protobuf.string(13, VisionOSDevice.current.model)
        info += Protobuf.int(16, 101)
        info += Protobuf.string(17, version)
        info += Protobuf.string(18, "visionOS")
        info += Protobuf.string(19, VisionOSDevice.current.osVersion)
        return info + SABRClientInfo.commonTail()
    }

    func sabrAbrState(_ state: SABRPlayerState) -> Data {
        var body = Protobuf.int(28, state.playerMs)
        if let height = state.video.height, height > 0 {
            body += Protobuf.int(21, height)             // stickyResolution
        }
        body += Protobuf.bool(22, false)                 // clientViewportIsFlexible
        body += Protobuf.int(34, 1)                      // visibility
        body += Protobuf.float(35, 1.0)                  // playbackRate
        body += Protobuf.int(40, state.wants.bitfield)   // enabledTrackTypes
        if let id = state.audioTrackId, !id.isEmpty {
            body += Protobuf.string(69, id)
        }
        return body
    }
}
