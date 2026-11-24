import AVFoundation
import UIKit

enum PlaybackBufferPolicy {
    static let defaultForwardBufferDuration: TimeInterval = 20.0
    static let backgroundBufferDuration: TimeInterval = 30.0

    static func configure(
        item: AVPlayerItem,
        forwardBufferDuration: TimeInterval = defaultForwardBufferDuration
    ) {
        item.preferredForwardBufferDuration = forwardBufferDuration
        // The session runs in .moviePlayback, which lets the system spatialize
        // even plain stereo on AirPods. Allow it only where the content really
        // has the channels for it (#119).
        if #available(iOS 15.0, *) {
            item.allowedAudioSpatializationFormats = .multichannel
        }
    }

    static func configure(
        player: AVPlayer,
        waitsToMinimizeStalling: Bool = true
    ) {
        player.automaticallyWaitsToMinimizeStalling =
            waitsToMinimizeStalling
        // Keeps audio going in the background without detaching the player
        // from its layer — the detach is what breaks PiP (#28). Older iOS
        // has no such policy and falls back to detaching.
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
    }
}

/// Drives source-based playback: picks a `VideoSource` via the factory, loads
/// it, and hands the prepared item to the `PlaybackContext` (player shell).
final class PlaybackFacade {
    /// Recoveries closer together than this are one failing streak; a lone
    /// one hours later (URL expiry) starts the ladder over.
    private static let recoveryStreakWindow: TimeInterval = 60
    /// Bound on visitor identities burned per video: churning them is itself a
    /// bot signal, and the clean one that lands is cached for every later video.
    static let maxIdentityRedraws = 5
    /// Breathing room between draws, so a run of them is not a burst.
    static let identityRedrawDelay: TimeInterval = 0.4

    weak var context: PlaybackContext?
    /// The active source — owns stream resolution and quality selection.
    var activeVideoSource: VideoSource?
    /// The chain underneath it, so a mid-playback failure can move on to the
    /// next step instead of starting the whole ladder again.
    var activeChain: FallbackChainSource?
    let watchtimeTracker = WatchtimeTracker()
    var currentVideoId: String?
    weak var currentApiClient: WatchService?
    /// Video that already burned its one silent bot-check retry.
    var botCheckRetriedVideoId: String?
    /// Consecutive mid-playback recoveries, for the escalation ladder.
    var recoveryAttempts = 0
    /// When the last recovery started — an isolated one (URL expiry hours
    /// later) must not count against the ladder.
    var lastRecoveryAt: Date?
    /// Visitor identities burned on the current video because googlevideo
    /// throttled them.
    var identityRedraws = 0
}

// MARK: - Public API

extension PlaybackFacade {
    func start(
        videoId: String,
        apiClient: WatchService,
        cancellationToken: CancellationToken,
        statusKey: String = "player.status.resolving"
    ) {
        if videoId != currentVideoId {
            identityRedraws = 0
        }
        currentVideoId = videoId
        currentApiClient = apiClient
        let source = buildChain(apiClient: apiClient, videoId: videoId)
        context?.updateStatusLabel(statusKey.localized)
        PlaybackProgress.report = { [weak self] text in
            self?.context?.updateStatusLabel(text)
        }
        let attempt = ResolveAttempt(
            videoId: videoId,
            apiClient: apiClient,
            cancellationToken: cancellationToken,
            startedAt: Date(),
            identityGeneration: InnertubeSession.identityGeneration
        )
        source.loadPlayback(
            videoId: videoId,
            cancellation: cancellationToken
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.finishResolve(result, attempt: attempt)
            }
        }
    }

    /// The user's chain, wrapped so a preferred dub can start on the step
    /// that lists dubs.
    private func buildChain(
        apiClient: WatchService,
        videoId: String
    ) -> VideoSource {
        let steps = PlaybackChainSettings.activeSteps()
        if DownloadStore.isDownloaded(videoId) {
            AppLog.player("chain: this video is downloaded, playing the file")
            // The chain rides along unloaded, purely so the quality menu can
            // offer what the network would serve. Nothing touches it until
            // the user picks one of those rows.
            let source = DownloadedSource(
                network: FallbackChainSource(steps: steps, apiClient: apiClient)
            )
            activeChain = nil
            activeVideoSource = source
            return source
        }
        if steps.isEmpty {
            AppLog.player("chain: no sources enabled for this session")
        }
        let chain = FallbackChainSource(steps: steps, apiClient: apiClient)
        activeChain = chain
        let source = AutoDubSource(wrapping: chain) { [weak chain] in
            chain?.dubCapableSource()
        }
        activeVideoSource = source
        return source
    }

    private func finishResolve(
        _ result: Swift.Result<PreparedPlayback, Error>,
        attempt: ResolveAttempt
    ) {
        let ms = Int(Date().timeIntervalSince(attempt.startedAt) * 1_000)
        let verdict = (try? result.get()) == nil ? "failed" : "ok"
        AppLog.player(
            "resolve \(verdict) on \(activeVideoSource?.name ?? "chain") in \(ms)ms"
        )
        guard !attempt.cancellationToken.isCancelled else {
            return
        }
        if retryOnFreshIdentity(result, attempt: attempt) {
            return
        }
        identityRedraws = 0
        handlePrepared(result, cancellation: attempt.cancellationToken)
    }

    /// Restarts playback after a mid-playback failure (segment 403, fatal
    /// stall). A source cannot see these itself — its manifest loaded fine —
    /// so the chain is walked from here: rebuild the same step once (that
    /// fixes genuine URL expiry), then move to the next step, then stop.
    /// Returns false when the budget is spent, and the shell shows the error
    /// rather than hammering the API forever.
    func recover(cancellationToken: CancellationToken) -> Bool {
        guard let videoId = currentVideoId,
              let apiClient = currentApiClient else {
            return false
        }
        if let last = lastRecoveryAt,
           Date().timeIntervalSince(last) > Self.recoveryStreakWindow {
            recoveryAttempts = 0
        }
        lastRecoveryAt = Date()
        recoveryAttempts += 1
        guard recoveryAttempts <= 2 else {
            AppLog.player("recovery: retries spent, giving up")
            return false
        }
        AppLog.player("recovery attempt \(recoveryAttempts)")
        // Once for a URL that simply expired; the second time the step itself
        // is failing, so the video goes to the next step in the user's chain.
        guard recoveryAttempts > 1, let chain = activeChain else {
            start(
                videoId: videoId,
                apiClient: apiClient,
                cancellationToken: cancellationToken,
                statusKey: "player.status.refreshing"
            )
            return true
        }
        context?.updateStatusLabel("player.status.refreshing".localized)
        advanceChain(chain, videoId: videoId, cancellationToken: cancellationToken)
        return true
    }

    private func advanceChain(
        _ chain: FallbackChainSource,
        videoId: String,
        cancellationToken: CancellationToken
    ) {
        chain.advance(videoId: videoId, cancellation: cancellationToken) { [weak self] result in
            DispatchQueue.main.async {
                self?.handlePrepared(result, cancellation: cancellationToken)
            }
        }
    }

    private func handlePrepared(
        _ result: Result<PreparedPlayback, Error>,
        cancellation: CancellationToken
    ) {
        // A chain advance for a recovery since superseded.
        guard !cancellation.isCancelled else {
            return
        }
        PlaybackProgress.report = nil
        switch result {
        case .success(let prepared):
            let name = activeVideoSource?.name ?? "?"
            let count = activeVideoSource?.availableQualities.count ?? 0
            AppLog.player("source \(name) playing, \(count) qualities")
            context?.attachPrepared(prepared, resumeAt: nil)
            fetchWatchtimeAndTrack()
        case .failure(let error):
            AppLog.player("source playback failed: \(error)")
            guard !PlaybackChainSettings.activeSteps().isEmpty else {
                // Every step is either switched off or needs an account that
                // is not there — say that rather than blame the stream.
                context?.showPlaybackError("player.error.noSources".localized)
                return
            }
            guard isBotCheck(error) else {
                context?.showPlaybackError("player.error.playback".localized)
                return
            }
            if !retryAfterBotCheck(cancellation: cancellation) {
                context?.showPlaybackError("player.error.botCheck".localized)
            }
        }
    }

    private func isBotCheck(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case .botCheck = apiError else {
            return false
        }
        return true
    }

    /// Parsing the bot check already dropped the flagged visitor identity, so
    /// one silent reload — fresh identity, whole source chain again — usually
    /// just plays. Only ever retried once per video; then the user sees why.
    private func retryAfterBotCheck(
        cancellation: CancellationToken
    ) -> Bool {
        guard let videoId = currentVideoId,
              let apiClient = currentApiClient,
              botCheckRetriedVideoId != videoId,
              !cancellation.isCancelled else {
            return false
        }
        botCheckRetriedVideoId = videoId
        AppLog.player("bot check — retrying with a fresh visitor identity")
        // The label stays up for the whole retry — `start` would immediately
        // overwrite anything set here with its own status.
        start(
            videoId: videoId,
            apiClient: apiClient,
            cancellationToken: cancellation,
            statusKey: "player.status.botCheckRetry"
        )
        return true
    }

    func reset() {
        activeVideoSource = nil
        watchtimeTracker.stop()
        currentVideoId = nil
        currentApiClient = nil
        botCheckRetriedVideoId = nil
        recoveryAttempts = 0
        lastRecoveryAt = nil
        identityRedraws = 0
    }
}
