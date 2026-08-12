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
        let target = lastPlaybackPosition
        AppLog.player(
            "recoverPlayback: ready"
                + " duration=\(CMTimeGetSeconds(item.duration))s"
                + " seekTo=\(target)s"
        )
        let time = CMTime(
            seconds: target,
            preferredTimescale: 1_000
        )
        videoPlayerView?.player?.seek(
            to: time,
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
