import AVFoundation
import UIKit

// MARK: - Stream URL Expiration Recovery

/// One recovery's bookkeeping.
struct RecoveryState {
    var startedAt: Date?
    /// Its own, so a newer recovery can cancel it: a stalled one left
    /// running would attach its item over the new one's.
    var token: CancellationToken?
    /// False when the user is only now coming back to the video: it is
    /// rebuilt and left paused rather than starting with sound.
    var resumesPlayback = true

    /// A recovery that should still be resolving — its item not ready yet.
    var isFresh: Bool {
        startedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
    }
}

extension WatchViewController {
    /// A recovery rebuilding a video the user is only now coming back to.
    var isPausedRecovery: Bool {
        pendingRecoverySeek && !recovery.resumesPlayback
    }

    func recoverPlayback(resume: Bool = true) {
        guard !isRecoveringPlayback,
              videoPlayerView?.player != nil
        else {
            return
        }
        AppLog.player(
            "recoverPlayback: resumeAt=\(lastPlaybackPosition)s"
        )
        recovery.token?.cancel()
        let token = CancellationToken()
        pageLoadToken = token
        guard playbackFacade.recover(cancellationToken: token) else {
            showPlaybackError("player.error.playback".localized)
            return
        }
        isRecoveringPlayback = true
        recovery = RecoveryState(startedAt: Date(), token: token, resumesPlayback: resume)
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
        let resume = recovery.resumesPlayback
        recovery = RecoveryState()
        let target = lastPlaybackPosition
        // A rebuilt stream that already opens at the playhead is where it
        // needs to be. Seeking there anyway leaves the player working the head
        // of the stream as well, which on SABR restarts it on every swap.
        if let startsAt = itemStartsAt, abs(startsAt - target) <= 1 {
            AppLog.player("recoverPlayback: ready at \(target)s, stream opened there")
            pendingRecoverySeek = false
            resumeAfterRecovery(resume)
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
            self?.resumeAfterRecovery(resume)
        }
        return true
    }

    private func resumeAfterRecovery(_ resume: Bool) {
        if resume {
            videoPlayerView?.player?.play()
        } else {
            videoPlayerView?.player?.pause()
            videoPlayerView?.setControls(visible: true, animated: true)
        }
    }

    /// A recovery whose own new item failed before it was ready is over:
    /// go again (the facade moves down the chain, then gives up with an
    /// error) rather than leave it marked in progress over a dead item.
    func recoverIfOwnItemFailed(_ item: AVPlayerItem?) -> Bool {
        guard isRecoveringPlayback, pendingRecoverySeek,
              item === videoPlayerView?.player?.currentItem else {
            return false
        }
        AppLog.player("recoverPlayback: the rebuilt item failed, trying again")
        isRecoveringPlayback = false
        recoverPlayback(resume: recovery.resumesPlayback)
        return true
    }
}
