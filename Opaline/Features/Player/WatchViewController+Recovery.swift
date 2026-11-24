import AVFoundation
import UIKit

// MARK: - Stream URL Expiration Recovery

extension WatchViewController {
    func recoverPlayback() {
        guard !isRecoveringPlayback,
              videoPlayerView?.player != nil
        else {
            return
        }
        // Paused, in the background, background playback off: nobody is
        // listening, and a stream rebuilt during a background wake-up would
        // only fail again once iOS suspends the app, loopback server and all.
        // Rebuild on return. A Play from the lock screen still recovers now.
        if UIApplication.shared.applicationState == .background,
           !BackgroundPlaybackService.isEnabled,
           videoPlayerView?.isPiPActive != true,
           videoPlayerView?.player?.rate == 0 {
            AppLog.player("recoverPlayback: in the background, deferred to foreground")
            recoverOnForeground = true
            return
        }
        AppLog.player(
            "recoverPlayback: resumeAt=\(lastPlaybackPosition)s"
        )
        let token = CancellationToken()
        pageLoadToken = token
        guard playbackFacade.recover(cancellationToken: token) else {
            showPlaybackError("player.error.playback".localized)
            return
        }
        isRecoveringPlayback = true
        recoveryItem = videoPlayerView?.player?.currentItem
        hasSeenPlaybackError = false
        pendingRecoverySeek = true
    }

    func applyRecoverySeekIfNeeded(
        _ item: AVPlayerItem
    ) -> Bool {
        guard pendingRecoverySeek else {
            return false
        }
        isRecoveringPlayback = false
        recoveryItem = nil
        let target = lastPlaybackPosition
        // A rebuilt stream that already opens at the playhead is where it
        // needs to be. Seeking there anyway leaves the player working the head
        // of the stream as well, which on SABR restarts it on every swap.
        if let startsAt = itemStartsAt, abs(startsAt - target) <= 1 {
            AppLog.player("recoverPlayback: ready at \(target)s, stream opened there")
            pendingRecoverySeek = false
            videoPlayerView?.player?.play()
            return true
        }
        AppLog.player(
            "recoverPlayback: ready"
                + " duration=\(CMTimeGetSeconds(item.duration))s"
                + " seekTo=\(target)s"
        )
        videoPlayerView?.player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 1_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            // An unfinished seek means another item took over mid-flight —
            // keep the gate closed so the next recovery still knows where
            // the user was.
            if finished {
                self?.pendingRecoverySeek = false
            }
            self?.videoPlayerView?.player?.play()
        }
        return true
    }
}
