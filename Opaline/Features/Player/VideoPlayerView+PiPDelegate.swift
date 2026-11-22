import AVKit
import UIKit

// MARK: - PiP Delegate

extension VideoPlayerView: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        pipTrace("delegate: willStart")
        pipIsStarting = true
        // Auto-PiP starts after `appDidEnterBackground` armed the lock pause;
        // PiP is the user watching, so locking must not pause it.
        ScreenLockPause.shared.arm(false)
        pipButton.setImage(
            PlayerIcons.pipExit(),
            for: .normal
        )
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        pipTrace("delegate: didStart")
        pipIsStarting = false
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        pipTrace("delegate: didStop restoring=\(pipIsRestoring)")
        pipIsStarting = false
        // ✕ closes the window *and* the playback behind it — that is what the
        // button means everywhere on iOS. Only a restore (the expand button)
        // hands playback back to the app, and AVKit pauses on that way out,
        // so there the previous state is put back instead.
        if pipIsRestoring {
            if wasPlayingOnResign, let player, player.rate == 0 {
                player.play()
            }
        } else {
            player?.pause()
        }
        pipIsRestoring = false
        pipButton.setImage(
            PlayerIcons.pip(),
            for: .normal
        )
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        AppLog.player("PiP failed to start: \(error)")
        pipTrace("delegate: failedToStart")
        pipIsStarting = false
        // AVKit reports readiness it cannot honour yet, so a start can still
        // land a moment too early. Only a start the user asked for is retried,
        // and only while the app is on screen: a retry from a background
        // auto-start would pop a window up on the way back instead.
        guard UIApplication.shared.applicationState == .active else {
            // `willStart` disarmed the lock pause and the background pause
            // skipped a starting PiP; with background playback off, a failed
            // auto-start would otherwise leave the audio playing.
            if !BackgroundPlaybackService.isEnabled {
                player?.pause()
            }
            return
        }
        startPiPWhenPossible(attempt: 50)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
            completionHandler: @escaping (Bool) -> Void
    ) {
        // Reached only when PiP is dismissed via its expand button, which is
        // what tells `didStop` apart from a ✕ dismissal.
        //
        // This callback means "put your own player UI back": expand the panel
        // so AVKit hands the picture to a layer that is actually on screen —
        // restoring into a collapsed panel flashes the whole app black.
        // Handing it to a layer without a player stops playback outright.
        pipTrace("delegate: restoreUI")
        pipIsRestoring = true
        wasPlayingOnResign = (player?.rate ?? 0) > 0
        VideoRouter.shared.expandPanel()
        if playerLayer.player == nil {
            playerLayer.player = player
        }
        completionHandler(true)
    }
}
