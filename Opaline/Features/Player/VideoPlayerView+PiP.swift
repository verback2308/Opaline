import AVKit
import UIKit

// MARK: - Picture in Picture

extension VideoPlayerView {
    /// Device support. The button is offered whenever the hardware allows it,
    /// regardless of the setting — the setting only governs *automatic* PiP.
    var isPiPAvailable: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    var isPiPActive: Bool {
        pipIsStarting || pipController?.isPictureInPictureActive == true
    }

    /// User setting: PiP on (the system may float the video when the app goes
    /// away, and the button is there) or off — no PiP at all, as in the
    /// official app.
    var isAutoPiPEnabled: Bool {
        UserDefaults.standard.object(
            forKey: UserDefaultsKeys.Player.pipEnabled
        ) as? Bool ?? true
    }

    /// The screen went dark, i.e. the device is locking rather than switching
    /// to another app. PiP cannot take over behind the lock screen, so waiting
    /// for it there only stalls the sound for a second before the audio
    /// fallback runs anyway. iOS exposes no lock state at all; this heuristic
    /// would misfire on an always-on display, which is safe because only the
    /// pre-iOS 15 path consults it.
    private var isScreenLocked: Bool {
        UIScreen.main.brightness == 0
    }

    /// Whether the system will start PiP by itself during the background
    /// transition — the layer must keep its player for that to work.
    ///
    /// AVKit has always done this for fullscreen playback;
    /// `canStartPictureInPictureAutomaticallyFromInline` (iOS 14.2) is what
    /// extends it to inline. Below that, inline gets background audio and the
    /// PiP button — starting PiP by hand is not an option, because the last
    /// callback before the transition is `willResignActive`, which Control
    /// Center and the notification shade raise just as loudly, and a start
    /// issued once the app is in the background is swallowed by AVKit without
    /// even a `failedToStart`.
    private var willAutoPiP: Bool {
        guard isAutoPiPEnabled, isPiPAvailable else {
            return false
        }
        if #available(iOS 14.2, *) {
            return true
        }
        return isFullscreen
    }

    /// Hands the current item to a replacement player and re-points every
    /// observer at it. Used to escape the iOS 12 state where a player that
    /// was detached from its layer can never enter PiP again (#28).
    func replacePlayer(_ newPlayer: AVPlayer) {
        removePeriodicObserver()
        removePlayerObservers()
        player = newPlayer
        playerLayer.player = newPlayer
        pipController = nil
        addPeriodicObserver()
        addPlayerObservers()
        setupPiP()
        updatePlayPauseIcon()
        // A PiP request that arrived before the swap waited for exactly this:
        // starting against the old, poisoned player fails with -1001.
        if pipStartPending {
            pipStartPending = false
            startPiPWhenPossible()
        }
    }

    /// With the setting off no controller is built at all, and that is the
    /// only thing that actually turns PiP off: from iOS 26 the system's
    /// "Start PiP Automatically" outranks
    /// `canStartPictureInPictureAutomaticallyFromInline`, so any controller
    /// that exists is one iOS can open on its own. A controller kept alive
    /// just for the button was what made the setting unenforceable — the
    /// official app hides its button for the same reason.
    /// Any write to the defaults lands here, from whichever thread made it —
    /// background network callbacks included — so the UI work is handed to
    /// the main thread before `setupPiP()` touches the button.
    @objc
    func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.setupPiP()
        }
    }

    func setupPiP() {
        let available = isPiPAvailable && isAutoPiPEnabled
        setControlAvailability(
            pipButton,
            available: available
        )
        guard available else {
            pipController = nil
            return
        }
        if pipController == nil {
            pipController = AVPictureInPictureController(
                playerLayer: playerLayer
            )
            pipController?.delegate = self
        }
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
    }

    /// Control Center / Notification Center peeks fire this without ever
    /// backgrounding the app, so nothing is torn down here — only the
    /// play state is remembered for the background resume.
    @objc
    func appWillResignActive() {
        // A hidden layer can keep auto-PiP from starting; nothing is on
        // screen to cover any more anyway.
        endResumeSeek()
        guard !isPiPActive else {
            return
        }
        wasPlayingOnResign = (player?.rate ?? 0) > 0
    }

    /// A real backgrounding: detach the layer (a layer-backed player is paused
    /// by iOS in the background) and resume audio. Deferred one tick because
    /// auto-PiP may still be starting and would lose its player.
    ///
    /// The detach is skipped whenever PiP is expected to take over: on iOS 12
    /// it permanently breaks PiP for this player — every later start fails
    /// with AVKitErrorDomain -1001, and neither a fresh controller nor a fresh
    /// layer revives it, only a new player (i.e. another video).
    @objc
    func appDidEnterBackground() {
        guard BackgroundPlaybackService.isEnabled else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.enterBackgroundAudioMode()
        }
    }

    private func enterBackgroundAudioMode(force: Bool = false) {
        // iOS 15+ keeps background audio alive through
        // `audiovisualBackgroundPlaybackPolicy`, so the layer never has to
        // give up its player — and PiP survives, lock screen included.
        if #available(iOS 15.0, *) {
            return
        }
        guard !isPiPActive else {
            return
        }
        // Waiting on the system's own auto-PiP: the layer has to keep its
        // player for that, so the audio fallback is held back until AVKit has
        // had its chance. It gets one second — a layer-backed player that is
        // neither in PiP nor detached is paused by iOS soon after (#31).
        if willAutoPiP, !force, !isScreenLocked {
            pipTrace("auto: waiting for the system")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.isPiPActive else {
                    return
                }
                self.pipTrace("auto: system did not start, audio only")
                self.enterBackgroundAudioMode(force: true)
            }
            return
        }
        playerLayer.player = nil
        playerNeedsRebuildForPiP = true
        if wasPlayingOnResign, let player, player.rate == 0 {
            player.play()
        }
    }

    @objc
    func appDidBecomeActive() {
        guard let player else {
            return
        }
        // While PiP runs, AVKit owns the player — rebinding it to the layer
        // here yanks it back and drops playback into a paused state.
        if playerLayer.player == nil, !isPiPActive {
            playerLayer.player = player
        }
        // We are the frontmost app again: undo the multitasking pause.
        if multitaskPause.systemPaused, !isPiPActive {
            multitaskPause.systemPaused = false
            if player.rate == 0 {
                player.play()
            }
        }
        // Re-evaluate the PiP setting (it may have changed in Settings).
        setupPiP()
    }

    @objc
    func pipTapped() {
        pipTrace("tap")
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
            return
        }
        // Below iOS 15 a background-audio session costs the player its ability
        // to enter PiP (the layer had to give it up), and only a fresh player
        // wins it back. That rebuild flashes the picture and rewinds a couple
        // of seconds, so it is paid here — once, by whoever actually asks for
        // PiP — instead of on every return from the background.
        if playerNeedsRebuildForPiP {
            playerNeedsRebuildForPiP = false
            pipStartPending = true
            onNeedsFreshPlayer?()
            return
        }
        startPiPWhenPossible()
    }

    /// A just-rebuilt player needs a moment before AVKit accepts a start, and
    /// that wait covers the fresh item's buffering — hence the generous
    /// budget. Polling because `isPictureInPicturePossible` is not KVO-safe
    /// to observe from an extension without extra stored state.
    func startPiPWhenPossible(attempt: Int = 0) {
        guard let pip = pipController, !pip.isPictureInPictureActive else {
            return
        }
        guard attempt < 60 else {
            pipTrace("wait: gave up")
            return
        }
        // `isPictureInPicturePossible` turns true before the rebuilt layer has
        // drawn its first frame, and a start in that window is swallowed
        // without a single delegate callback — wait for the picture as well.
        // `isReadyForDisplay` alone is not enough right after a player swap:
        // it still reports the frame of the *previous* item, so the start goes
        // out against an item that cannot serve it yet and fails with -1001.
        guard pip.isPictureInPicturePossible, playerLayer.isReadyForDisplay,
              player?.currentItem?.status == .readyToPlay
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startPiPWhenPossible(attempt: attempt + 1)
            }
            return
        }
        pip.startPictureInPicture()
    }
}
