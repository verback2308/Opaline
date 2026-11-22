import UIKit

/// Where the player has to go back to once fullscreen ends.
struct FullscreenSnapshot {
    let superview: UIView
    let frame: CGRect
}

// MARK: - Fullscreen

extension WatchViewController {
    func enterFullscreen(playerView: VideoPlayerView, animated: Bool = true) {
        guard let window = view.window else {
            return
        }
        detachPlayerToWindow(playerView, window: window)
        updateQueueBar()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        guard animated else {
            playerView.frame = window.bounds
            playerView.applyAutoZoomIfNeeded()
            return
        }
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: .curveEaseInOut,
            animations: {
                playerView.frame = window.bounds
            },
            completion: { _ in
                playerView.applyAutoZoomIfNeeded()
            }
        )
    }

    private func detachPlayerToWindow(
        _ playerView: VideoPlayerView,
        window: UIWindow
    ) {
        let frameInWindow = playerView.convert(
            playerView.bounds, to: window
        )
        fullscreenSnapshot = FullscreenSnapshot(
            superview: playerView.superview ?? view,
            frame: playerView.frame
        )
        playerView.removeFromSuperview()
        playerView.translatesAutoresizingMaskIntoConstraints = true
        // Allow the player to resize with the window when the device rotates while
        // in fullscreen, so the video fills the screen in the new orientation.
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerView.frame = frameInWindow
        window.addSubview(playerView)
        playerView.isFullscreen = true
    }

    func exitFullscreen(playerView: VideoPlayerView, animated: Bool = true) {
        guard let window = view.window,
              let snap = fullscreenSnapshot else {
            return
        }
        // Ask for the status bar now, so it slides back in alongside the
        // shrinking player. Asked for at the end of the animation instead, it
        // arrives half a second late and shoves the settled layout down.
        isLeavingFullscreen = true
        setNeedsStatusBarAppearanceUpdate()
        let target = snap.superview.convert(snap.frame, to: window)
        guard animated else {
            restoreFromFullscreen(playerView: playerView, snapshot: snap)
            return
        }
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: .curveEaseInOut,
            animations: {
                playerView.frame = target
            }, completion: { [weak self] _ in
                self?.restoreFromFullscreen(
                    playerView: playerView, snapshot: snap
                )
            }
        )
    }

    func restoreFromFullscreen(
        playerView: VideoPlayerView,
        snapshot: FullscreenSnapshot
    ) {
        playerView.removeFromSuperview()
        let sv = snapshot.superview
        playerView.transform = .identity
        playerView.bounds = CGRect(origin: .zero, size: snapshot.frame.size)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.autoresizingMask = []
        sv.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: sv.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: sv.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: sv.bottomAnchor)
        ])
        playerView.isFullscreen = false
        fullscreenSnapshot = nil
        isLeavingFullscreen = false
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        updateLayoutForSize()
        updateQueueBar()
    }
}

// MARK: - Open in fullscreen (iPad)

extension WatchViewController {
    static var opensVideosInFullscreen: Bool {
        UserDefaults.standard.bool(
            forKey: UserDefaultsKeys.Player.openInFullscreen
        )
    }

    /// Called when the user opens a video — from a feed, a link, the related
    /// list or the queue. Autoplay and queue advances never call it, so they
    /// never force fullscreen. Remembered by id, so a request whose video
    /// never got a player cannot fire on whatever plays next. iPhone is left
    /// alone (the orientation decides there), and so are shorts, which would
    /// fill a landscape screen with side bars.
    func requestAutoFullscreenIfEnabled(for video: Video) {
        let wanted = UIDevice.current.userInterfaceIdiom == .pad
            && Self.opensVideosInFullscreen
            && !video.isShort
        autoFullscreenVideoId = wanted ? video.id : nil
    }

    /// Minimizing before the player arrived takes the request back.
    func cancelAutoFullscreen() {
        autoFullscreenVideoId = nil
    }

    /// Runs once a player is attached — the first moment there is a player
    /// view to move into the window. Consumes the request either way.
    func enterAutoFullscreenIfRequested() {
        let requested = autoFullscreenVideoId
        autoFullscreenVideoId = nil
        guard requested == initialVideo.id,
              !AudioOnlyMode.isEnabled,
              let playerView = videoPlayerView,
              !playerView.isFullscreen,
              view.window != nil else {
            return
        }
        enterFullscreen(playerView: playerView)
    }
}
