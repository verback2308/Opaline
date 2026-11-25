import AVFoundation
import Foundation

/// Innertube adaptive-format source: fetches adaptive DASH formats and plays
/// them as a SIDX-generated HLS stream (with native-HLS / progressive
/// fallbacks). Owns quality selection from the DASH ladder.
///
/// Serves two clients through one code path, because the difference between
/// them is the request, not the playback: `androidVR` (anonymous, formats carry
/// URLs) and `tv` (OAuth, SABR-only). Which delivery runs follows from what the
/// response carries, so the TV client lands on SABR without a branch here.
final class InnertubeVideoSource: VideoSource {
    static let deliveryUnavailableError = NSError(
        domain: "InnertubeVideoSource",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Delivery cannot serve this response"]
    )
    private static let noStreamError = NSError(
        domain: "InnertubeVideoSource",
        code: 0,
        userInfo: [NSLocalizedDescriptionKey: "No playable stream"]
    )

    let name: String
    var supportsQualitySelection: Bool { !availableQualities.isEmpty }
    var currentCodecs: String? {
        guard let line = Self.codecsLine(
            info: info, quality: currentQuality, audio: currentAudioFormat
        ) else {
            return nil
        }
        guard let delivery, delivery.label != "range" else {
            return line
        }
        return "\(line) [\(delivery.label)]"
    }
    private(set) var availableQualities: [VideoQuality] = []
    private(set) var currentQuality: VideoQuality?
    // Written by the audio-track extension; see InnertubeVideoSource+AudioTracks.
    var availableAudioTracks: [AudioTrack] = []
    var currentAudioTrack: AudioTrack?
    /// The audio format playback is built with — the picked dub, or the
    /// format the response defaulted to.
    var currentAudioFormat: DashFormatInfo?

    let apiClient: WatchService
    let transport: HTTPTransport
    /// How the bytes are arriving right now — byte ranges or SABR.
    var delivery: StreamDelivery?
    /// The decoded po token this source's SABR sessions stream under (TV only).
    var sabrPoToken: Data?
    private let liveHLS: LiveHLSPlayback
    let client: PlaybackClient
    /// How this source's bytes arrive — one delivery, chosen when the source
    /// was created rather than guessed from the response.
    let deliveryFactory: StreamDeliveryFactory
    var listsAudioTracks: Bool { client.listsAudioTracks }
    private(set) var info: DirectPlaybackInfo?
    /// The video `info` belongs to — a rebuild with no playhead of its own
    /// (the auto-dub start) needs it to find the saved one. Also set by the
    /// metadata probe, which runs before any `/player` fetch.
    var currentVideoId: String?
    /// A track the probe picked before this source had a `/player` response.
    /// The first build then starts on it directly instead of building the
    /// original and rebuilding a second later.
    var pendingAudioTrackId: String?
    let poTokenProvider: PoTokenProvider

    init(
        apiClient: WatchService,
        client: PlaybackClient,
        name: String,
        deliveryFactory: StreamDeliveryFactory,
        transport: HTTPTransport = ServiceContainer.mediaTransport,
        resolver: HLSStreamResolver = .shared,
        poTokenProvider: PoTokenProvider = RemotePoTokenService.shared
    ) {
        self.apiClient = apiClient
        self.transport = transport
        self.client = client
        self.name = name
        self.deliveryFactory = deliveryFactory
        self.poTokenProvider = poTokenProvider
        liveHLS = LiveHLSPlayback(resolver: resolver)
    }

    func loadPlayback(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        fetchInfo(videoId: videoId, cancellation: cancellation) { [weak self] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let info):
                self?.handleInfo(info, videoId: videoId, completion: completion)
            }
        }
    }

    /// One `/player` fetch for this source's client, minting whatever token it
    /// needs first. Shared with the metadata-only audio-track probe.
    func fetchInfo(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<DirectPlaybackInfo, Error>) -> Void
    ) {
        currentVideoId = videoId
        mintingTokenIfNeeded { [weak self] poToken in
            guard let self else {
                return
            }
            apiClient.fetchDirectPlayback(
                videoId: videoId,
                client: client,
                poToken: poToken,
                cancellationToken: cancellation,
                completion: completion
            )
        }
    }

    func releaseResources() {
        releaseDelivery()
    }

    func selectQuality(
        _ quality: VideoQuality,
        resumeAt: Double?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        if liveHLS.isActive {
            selectLiveQuality(quality, completion: completion)
            return
        }
        guard let info,
              let format = AudioOnlyMode.resolveFormat(
                  for: quality, info: info, current: currentQuality
              ),
              let audio = audioFormat(in: info) else {
            completion(.failure(Self.noStreamError))
            return
        }
        currentQuality = quality
        buildGeneratedHLS(
            info: info,
            video: format,
            audio: audio,
            resumeAt: resumeAt,
            completion: completion
        )
    }

    // MARK: - Private

    private func handleInfo(
        _ info: DirectPlaybackInfo,
        videoId: String,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        apply(info)
        // Build straight at the saved playhead: a sequential stream (SABR)
        // would otherwise deliver the opening minutes and be seeked away from
        // them the moment the item turns ready.
        let resumeAt = WatchProgressStore.shared.resumeSeconds(
            forVideoId: videoId, duration: info.duration
        )
        logStartPoint(resumeAt, videoId: videoId, duration: info.duration)
        buildBest(info: info, resumeAt: resumeAt, completion: completion)
    }

    /// Publishes what a `/player` response says about tracks and qualities,
    /// without building anything from it.
    func apply(_ info: DirectPlaybackInfo) {
        self.info = info
        liveHLS.reset()
        updateAudioTrackState(from: info)
        availableQualities = Self.qualities(from: info)
        let defaultQuality = info.dashVideoFormat.flatMap { selected in
            availableQualities.first { $0.id == "\(selected.itag)" }
        }
        currentQuality = AudioOnlyMode.startQuality(
            in: availableQualities, fallback: defaultQuality
        )
    }

    private func buildBest(
        info: DirectPlaybackInfo,
        resumeAt: Double?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        if let video = info.dashVideoFormat, let audio = audioFormat(in: info) {
            buildGeneratedHLS(
                info: info,
                video: video,
                audio: audio,
                resumeAt: resumeAt,
                completion: completion
            )
        } else if let hls = info.hlsManifestURL {
            loadLiveHLS(info: info, url: hls, completion: completion)
        } else if let progressive = info.progressiveURL {
            let item = progressiveItem(progressive, info: info)
            completion(.success(prepared(item: item, info: info)))
        } else {
            completion(.failure(Self.noStreamError))
        }
    }

    func buildGeneratedHLS(
        info: DirectPlaybackInfo,
        video: DashFormatInfo,
        audio: DashFormatInfo,
        resumeAt: Double? = nil,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        AppLog.player(
            "\(name): building with audio \(audio.audioTrackId ?? "default")"
                + " itag \(audio.itag) xtags \(audio.xtags ?? "-")"
        )
        deliver(
            DeliveryRequest(info: info, video: video, audio: audio, resumeAt: resumeAt),
            completion: completion
        )
    }

    private func progressiveItem(
        _ url: URL, info: DirectPlaybackInfo
    ) -> AVPlayerItem {
        let headers = client.streamHeaders(visitorData: info.visitorData)
        let asset = AVURLAsset(
            url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]
        )
        return AVPlayerItem(asset: asset)
    }

    private func prepared(
        item: AVPlayerItem, info: DirectPlaybackInfo
    ) -> PreparedPlayback {
        PreparedPlayback(
            item: item, captions: info.captionTracks, duration: info.duration
        )
    }
}

// MARK: - Live HLS

private extension InnertubeVideoSource {
    /// Live streams (no DASH SIDX ladder): [[LiveHLSPlayback]] exposes the
    /// multivariant playlist's variants as qualities and starts on Auto. A
    /// failed playlist fetch degrades to direct playback with no picker.
    func loadLiveHLS(
        info: DirectPlaybackInfo,
        url: URL,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        liveHLS.load(url: url, info: info) { [weak self] prepared in
            guard let self else {
                return
            }
            if !liveHLS.qualities.isEmpty {
                availableQualities = liveHLS.qualities
                currentQuality = liveHLS.startQuality
            }
            completion(.success(prepared))
        }
    }

    func selectLiveQuality(
        _ quality: VideoQuality,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        guard let info,
              let prepared = liveHLS.prepared(for: quality, info: info) else {
            completion(.failure(Self.noStreamError))
            return
        }
        currentQuality = quality
        completion(.success(prepared))
    }
}

extension InnertubeVideoSource {
    /// Where the stream is built from, and what decided it: a stream built
    /// from the start has to be seeked to the saved position once ready.
    func logStartPoint(_ resumeAt: Double?, videoId: String, duration: Double?) {
        let store = WatchProgressStore.shared
        let saved = store.progress(forVideoId: videoId)?.fraction
        AppLog.player(
            "\(name): building from \(resumeAt.map { "\(Int($0))s" } ?? "the start")"
                + " (saved \(saved.map { "\($0)" } ?? "none"),"
                + " duration \(duration.map { "\(Int($0))s" } ?? "none"),"
                + " suppressed \(store.suppressResume))"
        )
    }
}
