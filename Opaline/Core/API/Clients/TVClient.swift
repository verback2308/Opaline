import Foundation

/// The living-room client, played under the account.
///
/// The only client our device-code OAuth token is accepted by, and the only
/// one served what an anonymous session is refused: dubs, kids content, and
/// media past the first minute of a video. SABR-only — its formats carry no
/// `url` — and its media URLs carry an `n` the solver has to answer.
struct TVClient: PlaybackClient {
    let name = "TVHTML5"
    let headerName = "7"
    let userAgent = UserAgent.webOSTV
    let playerURL = InnertubeEndpoint.player
    let authorization = PlaybackAuthorization.bearer
    /// Cookieless on purpose: this client authenticates with the bearer, and
    /// the shared jar belongs to whatever else has been on the wire. The same
    /// body sent from a jar-less shell mints a URL googlevideo serves, while
    /// the app's mint comes back marked `pcm2cms=yes` and is refused
    /// (measured 2026-08-18, same account, same public IP).
    let sendsCookies = false
    let needsSignatureSolver = true
    let listsAudioTracks = true

    /// The stream server serves a television only after it proves itself, and
    /// the token binds to this install's living-room id.
    var attestationBinding: String? { TVDeviceIdentity.livingRoomPoTokenId }

    /// Whatever `youtube.com/tv` is running, scraped beside the player path.
    /// Pinning it left `cver` naming a client YouTube no longer serves, which
    /// googlevideo answers with 403.
    var version: String {
        SignatureTimestampService.tvClientVersion ?? "7.20260816.19.00"
    }

    var innertubeContext: [String: Any] { InnertubeContexts.tv }

    /// The height this session may be served up to: a real television claims
    /// 1080, and claiming less would ask the server to withhold formats we can
    /// play — so the setting only ever raises the ceiling.
    private static func decodeCeiling() -> Int {
        max(1_080, VideoQualityStore.onDemandMaxHeight ?? 1_080)
    }

    /// What the set can decode — the shape a television sends, with our own
    /// ceiling in place of its fixed 1080.
    private static func decodeCeilings() -> Data {
        var caps = Protobuf.int(1, 0)
        caps += Protobuf.int(2, decodeCeiling())
        caps += Protobuf.int(3, 0)
        caps += Protobuf.int(4, 0)
        caps += Protobuf.int(5, decodeCeiling())
        caps += Protobuf.int(6, 0)
        return caps
    }

    /// Which track types this client may be served and whether HDR is allowed
    /// for each. A television claims audio, SDR video and HDR video — the same
    /// three entries every time.
    private static func trackAuthorization() -> Data {
        let entries = [(1, false), (2, false), (2, true)]
        return entries.reduce(Data()) { authorization, entry in
            var format = Protobuf.int(1, entry.0)   // trackType
            format += Protobuf.bool(2, entry.1)     // isHdr
            return authorization + Protobuf.bytes(1, format)
        }
    }

    /// A television names itself in the player context, and the version here
    /// has to be the one the headers and the media URL's `cver` name — or the
    /// three describe three different televisions.
    func decoratePlayerBody(_ body: inout [String: Any]) {
        guard var context = body["context"] as? [String: Any],
              var client = context["client"] as? [String: Any] else {
            return
        }
        client["tvAppInfo"] = [
            "livingRoomPoTokenId": TVDeviceIdentity.livingRoomPoTokenId,
            "signedInAccountCount": 1,
            "appQuality": "TV_APP_QUALITY_FULL_ANIMATION"
        ]
        client["clientVersion"] = version
        context["client"] = client
        body["context"] = context
    }

    func apiHeaders(token: String, visitorData: String?) -> [String: String] {
        var headers = defaultAPIHeaders(token: token, visitorData: visitorData)
        headers[HTTPHeader.referer] = AppURLs.YouTube.base + "/tv"
        return headers
    }

    func sabrClientInfo() -> Data {
        var info = Protobuf.int(16, 7)
        info += Protobuf.string(17, version)
        info += Protobuf.string(18, "Cobalt")
        info += Protobuf.string(19, "22.lts.3.306369-gold")
        return info + SABRClientInfo.commonTail()
    }

    /// Field for field what a television sends, captured from a live TV
    /// session 2026-08-16. Not the set the anonymous clients use: no
    /// `enabledTrackTypes`, `visibility` is 0 rather than 1, and it states DRC
    /// and codec preferences the others leave out.
    func sabrAbrState(_ state: SABRPlayerState) -> Data {
        var body = Protobuf.int(18, 1_920)        // clientViewportWidth
        body += Protobuf.int(19, 1_080)           // clientViewportHeight
        body += Protobuf.int(21, 0)               // stickyResolution
        if let bitrate = state.video.bitrate, bitrate > 0 {
            body += Protobuf.int(23, bitrate)     // bandwidthEstimate
        }
        body += Protobuf.int(28, state.playerMs)
        body += Protobuf.int(34, 0)               // visibility
        body += Protobuf.bool(46, true)           // drcEnabled
        body += Protobuf.bool(58, false)          // preferVp9
        body += Protobuf.int(59, Self.decodeCeiling()) // av1QualityThreshold
        if let id = state.audioTrackId, !id.isEmpty {
            body += Protobuf.string(69, id)
        }
        body += Protobuf.bytes(72, Self.decodeCeilings())
        body += Protobuf.int(73, 2)
        body += Protobuf.bytes(79, Self.trackAuthorization())
        body += Protobuf.int(80, 1)
        body += Protobuf.int(85, 1)
        return body
    }
}
