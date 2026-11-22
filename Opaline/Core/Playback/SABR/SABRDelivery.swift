import AVFoundation
import Foundation

/// Delivers playback over SABR (`serverAbrStreamingUrl` + UMP) instead of the
/// legacy `adaptiveFormats` URLs.
///
/// Those URLs stop serving about a minute after they are minted unless the
/// visitor identity happens to be a clean one, which is what
/// `PlaybackFacade+Identity` works around by re-drawing identities until one
/// passes. SABR needs none of that: identities the legacy probe rejects with
/// 403 stream over SABR without complaint (measured 2026-08-14, including an
/// identity burned down on purpose), so playback starts immediately with no
/// probe and no re-draws.
///
/// The bytes are fMP4 laid out exactly like the file behind the legacy URL —
/// the init segment carries `moov` and `sidx`, and `MEDIA_HEADER.start_range`
/// is an offset into that same file — so AVPlayer's byte-range reads map
/// straight onto the session. It reaches AVPlayer through a loopback HTTP
/// server rather than a resource loader; see `SABRDelivery+Serving`.
final class SABRDelivery: StreamDelivery {
    /// One stream as the serving layer sees it: the format, its segment index
    /// from `sidx`, and the path it is served under.
    struct Track {
        let format: DashFormatInfo
        let segments: [SidxSegment]
        let path: String
        /// The init segment it was built from (ftyp, moov and sidx).
        var initData = Data()
    }

    let label = "sabr"

    private let transport: HTTPTransport
    private var fetcher: SABRFetcher?
    /// One server for the whole delivery; sessions come and go behind it.
    var server: LocalMediaServer?
    var serverBase: URL?
    /// Bumped per session so each one gets fresh playlist URLs.
    var generation = 0
    /// Where the next attached item should start, set by a quality switch.
    var pendingStartAt: Double?
    /// One playback nonce per delivery, as a television has one per playback.
    private let nonce = PlaybackNonce.make()

    /// What the server routes to right now.
    ///
    /// Written when playback is built and read by the server on its own queue,
    /// so every access takes the lock. An unsynchronised struct holding an
    /// array is exactly the kind of data race that corrupts memory and then
    /// crashes somewhere unrelated.
    private var storedRoute: Route?
    private let routeLock = NSLock()

    var route: Route? {
        get {
            routeLock.lock()
            defer { routeLock.unlock() }
            return storedRoute
        }
        set {
            routeLock.lock()
            storedRoute = newValue
            routeLock.unlock()
        }
    }

    private let client: PlaybackClient
    /// Carried per delivery rather than globally: two sources can hold live
    /// sessions at once, and a shared one would have them rewriting each
    /// other's requests.
    private let identity: SABRIdentity

    init(
        transport: HTTPTransport,
        client: PlaybackClient,
        poToken: Data? = nil
    ) {
        self.client = client
        self.transport = transport
        identity = SABRIdentity(client: client, poToken: poToken)
    }

    /// `videoPlaybackUstreamerConfig` arrives web-safe base64 and unpadded.
    static func decodeConfig(_ value: String) -> Data? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }

    static func formatInfo(_ format: DashFormatInfo) -> SabrFormatInfo {
        // `xtags` is required whenever the format has one — without it the
        // server answers with policy and no media. An itag alone only works
        // for videos with a single audio track, which is what made an earlier
        // spike say it was optional.
        SabrFormatInfo(
            itag: format.itag,
            // A television identifies a format by itag *and* the moment it was
            // encoded; the pair is what the stream server matches against the
            // ladder it authorised.
            lastModified: format.lastModified,
            xtags: format.xtags,
            audioTrackId: format.audioTrackId,
            isDrc: false,
            mimeType: format.mimeType,
            bitrate: format.bitrate,
            width: format.width,
            height: format.height
        )
    }

    /// Whether a response can be played this way at all.
    static func canServe(_ info: DirectPlaybackInfo) -> Bool {
        info.serverAbrStreamingURL != nil && info.videoPlaybackUstreamerConfig != nil
    }

    /// The two init requests an open needs: each format's opening, with the
    /// other one declined.
    ///
    /// They carry the position playback is about to start from, not zero:
    /// that is what googlevideo's adapter sends for an init segment, and it is
    /// what has the server open the session where the viewer actually is.
    private static func initRequests(for request: DeliveryRequest) -> [SABRSegmentRequest] {
        let audio = formatInfo(request.audio)
        let video = formatInfo(request.video)
        let audioEnd = request.info.dashAudioFormat?.indexRangeEnd ?? 0
        let startMs = Int((request.resumeAt ?? 0) * 1_000)
        return [
            SABRSegmentRequest(
                format: video,
                other: audio,
                sequence: 1,
                timeMs: startMs,
                initRange: request.video.indexRangeEnd + 1
            ),
            SABRSegmentRequest(
                format: audio,
                other: video,
                sequence: 1,
                timeMs: startMs,
                initRange: audioEnd + 1
            )
        ]
    }

    func prepare(
        _ request: DeliveryRequest,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard let url = request.info.serverAbrStreamingURL,
              let configString = request.info.videoPlaybackUstreamerConfig,
              let config = Self.decodeConfig(configString) else {
            completion(.failure(SABRError.server("player response carries no SABR stream")))
            return
        }
        pendingStartAt = request.resumeAt
        PlaybackProgress.step("player.status.openingSABR")
        // `cpn` and `alr` because a television sends them; `cver` comes with
        // `directURL`. The token stays in the request body, where a television
        // keeps it.
        let signed = Self.televisionParams(
            client.directURL(baseURL: url, poToken: nil), cpn: nonce
        )
        Self.solvingThrottle(signed) { [weak self] solved in
            self?.openSession(request, url: solved, config: config, completion: completion)
        }
    }

    /// Fetches the two init segments — `ftyp/moov/sidx`, everything AVPlayer
    /// needs before any media — and builds the playback around them.
    private func openSession(
        _ request: DeliveryRequest,
        url: URL,
        config: Data,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        let fetcher = SABRFetcher(
            transport: transport,
            url: url,
            ustreamerConfig: config,
            identity: identity
        )
        self.fetcher = fetcher
        fetchInits(with: fetcher, for: request) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let inits):
                self?.buildPlayback(
                    request, fetcher: fetcher, inits: inits, completion: completion
                )
            }
        }
    }

    /// Both init segments at once — they are independent requests and the
    /// player needs both before it can build anything.
    private func fetchInits(
        with fetcher: SABRFetcher,
        for request: DeliveryRequest,
        completion: @escaping (Result<[Int: Data], Error>) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var inits: [Int: Data] = [:]
        var failure: Error?
        for want in Self.initRequests(for: request) {
            group.enter()
            fetcher.fetch(want) { result in
                lock.lock()
                inits[want.format.itag] = try? result.get()
                if case .failure(let error) = result {
                    failure = error
                }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            completion(failure.map { .failure($0) } ?? .success(inits))
        }
    }

    /// Stops what serves the current route: its fetcher and any transcoder.
    func stopRoute() {
        route?.fetcher.stop()
        route?.transcode?.close()
    }

    /// Playback moving elsewhere drops this delivery; the loopback server and
    /// the session have to go with it rather than linger until collection. A
    /// session left running keeps fetching the video that was closed.
    deinit {
        server?.stop()
        stopRoute()
    }
}
