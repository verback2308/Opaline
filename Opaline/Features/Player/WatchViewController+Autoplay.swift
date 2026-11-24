import UIKit

// MARK: - End of item

extension WatchViewController {
    /// The one place playback-ended is decided, for every player state:
    /// it hangs off `AVPlayerItemDidPlayToEndTime`, so backgrounded and
    /// PiP playback take the same branch as an on-screen player.
    @objc
    func playerItemDidPlayToEnd(
        _ notification: Notification
    ) {
        // Loop beats every autoplay path: no queue jump, no countdown. The
        // watchtime tracker keeps running with the same cpn, so the repeats
        // fold into the session it already opened instead of stacking up as
        // new history entries.
        if videoPlayerView?.isLooping == true {
            AppLog.player("playToEnd: loop restart")
            DispatchQueue.main.async { [weak self] in
                self?.videoPlayerView?.replay()
            }
            return
        }
        if let next = queue.nextVideo {
            playQueueEntry(next)
            return
        }
        guard AutoplayPreference.isEnabled,
              let nextVideo = watchPage?.nextVideo else {
            showEndScreen(reason: "no next video or autoplay off")
            return
        }
        playSuggestion(nextVideo)
    }

    /// Queue playback (mix/playlist) jumps straight to the next entry — the
    /// countdown overlay is suggestion-autoplay only. The queue is peeked,
    /// not advanced: navigation syncs it via seekTo.
    private func playQueueEntry(_ next: Video) {
        guard AutoplayPreference.isMixEnabled else {
            showEndScreen(reason: "queue next=\(next.id), mix autoplay off")
            return
        }
        AppLog.player("playToEnd: queue next=\(next.id)")
        DispatchQueue.main.async { [weak self] in
            // On main: the hold reads applicationState.
            guard let self, !self.holdsAutoplayInBackground(next) else {
                return
            }
            self.navigateTo(next)
        }
    }

    private func playSuggestion(_ nextVideo: Video) {
        // applicationState is main-thread-only and this notification can
        // arrive off-main — read it inside the hop.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            let active = UIApplication.shared.applicationState == .active
            AppLog.player(
                "playToEnd: suggestion=\(nextVideo.id) active=\(active)"
            )
            if active {
                self.showAutoplayOverlay(for: nextVideo)
            } else if !self.holdsAutoplayInBackground(nextVideo) {
                self.navigateTo(nextVideo)
            }
        }
    }
}

// MARK: - Autoplay

extension WatchViewController {
    func showAutoplayOverlay(for video: Video) {
        AppLog.player(
            "autoplay overlay: showing for \(video.id),"
                + " fullscreen=\(videoPlayerView?.isFullscreen == true)"
        )
        autoplayOverlay?.removeFromSuperview()
        let overlay = makeAutoplayOverlay(for: video)
        if let pv = videoPlayerView, pv.isFullscreen {
            overlay.translatesAutoresizingMaskIntoConstraints = true
            overlay.frame = pv.bounds
            overlay.autoresizingMask = [
                .flexibleWidth, .flexibleHeight
            ]
            pv.addSubview(overlay)
        } else {
            overlay
                .translatesAutoresizingMaskIntoConstraints
                = false
            playerContainer.addSubview(overlay)
            applyEdgeConstraints(
                overlay,
                to: playerContainer
            )
        }
        autoplayOverlay = overlay
        UIView.animate(withDuration: 0.25) {
            overlay.alpha = 1
        }
        overlay.startCountdown()
    }

    private func makeAutoplayOverlay(
        for video: Video
    ) -> AutoplayOverlayView {
        let overlay = AutoplayOverlayView(
            nextVideo: video,
            countdownSecs: 5
        )
        overlay.alpha = 0
        overlay.onPlay = { [weak self] in
            // The countdown can run out after the screen locked.
            if self?.holdsAutoplayInBackground(video) == true {
                return
            }
            self?.dismissAutoplayOverlay()
            self?.navigateTo(video)
        }
        overlay.onCancel = { [weak self] in
            self?.dismissAutoplayOverlay()
            // The video is still parked on its last frame: pressing Play
            // there resumes nothing and hangs on the spinner.
            self?.showEndScreen(reason: "autoplay cancelled")
        }
        return overlay
    }

    func applyEdgeConstraints(
        _ child: UIView,
        to parent: UIView
    ) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(
                equalTo: parent.topAnchor
            ),
            child.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor
            ),
            child.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor
            ),
            child.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor
            )
        ])
    }

    /// Previous walks the session's own back stack, so it stays greyed out
    /// until the first in-player navigation.
    func updateTransportAvailability() {
        videoPlayerView?.hasPreviousVideo = !videoHistory.isEmpty
        videoPlayerView?.updateCenterIcons()
    }

    /// Nothing plays after this video: Play becomes Replay and the controls
    /// stay on screen.
    func showEndScreen(reason: String) {
        AppLog.player("playToEnd: end screen — \(reason)")
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.updateTransportAvailability()
            self.videoPlayerView?.isAtEnd = true
            self.videoPlayerView?.setControls(visible: true, animated: true)
            self.videoPlayerView?.pauseAutoHide()
        }
    }

    /// Control Center / AirPods "next": queue entry first, else the top
    /// suggestion — always instant, never the countdown overlay.
    func playNextFromRemote() {
        dismissAutoplayOverlay()
        if let next = queue.nextVideo {
            AppLog.player("remote next: queue \(next.id)")
            navigateTo(next)
            return
        }
        guard let suggestion = watchPage?.nextVideo else {
            AppLog.player("remote next: nothing to play")
            return
        }
        AppLog.player("remote next: suggestion \(suggestion.id)")
        navigateTo(suggestion)
    }

    /// Control Center / AirPods "previous": the session's own back stack
    /// (`videoHistory`, same as the nav-bar back button). On a mix the
    /// reloaded watch page re-syncs the queue to the earlier position.
    /// With no history left, restart the video — the standard fallback.
    func previousFromRemote() {
        dismissAutoplayOverlay()
        guard videoHistory.isEmpty else {
            AppLog.player("remote previous: history back")
            goBack()
            return
        }
        AppLog.player("remote previous: restart")
        videoPlayerView?.player?.seek(
            to: .zero,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        videoPlayerView?.player?.play()
    }

    func dismissAutoplayOverlay() {
        guard let overlay = autoplayOverlay else {
            return
        }
        autoplayOverlay = nil
        UIView.animate(
            withDuration: 0.2,
            animations: { overlay.alpha = 0 },
            completion: { _ in
                overlay.removeFromSuperview()
            }
        )
    }
}

// MARK: - Background playback off

extension WatchViewController {
    /// With background playback off nothing plays while the app is in the
    /// background, so moving on to the next video there only loads it
    /// unseen — its page with the network asleep, its playback paused.
    /// Leave the next video to the countdown on return instead.
    func holdsAutoplayInBackground(_ next: Video) -> Bool {
        // Background only: a countdown ending under Control Center (inactive)
        // still plays on, as the app is on screen.
        guard UIApplication.shared.applicationState == .background,
              !BackgroundPlaybackService.isEnabled,
              videoPlayerView?.isPiPActive != true else {
            return false
        }
        AppLog.player("autoplay: holding \(next.id) until the app is back")
        dismissAutoplayOverlay()
        heldAutoplay = next
        return true
    }

    /// On return, the held next video gets its countdown as if the
    /// previous one had just ended.
    func resumeHeldAutoplay() {
        guard let next = heldAutoplay else {
            return
        }
        heldAutoplay = nil
        showAutoplayOverlay(for: next)
    }
}
