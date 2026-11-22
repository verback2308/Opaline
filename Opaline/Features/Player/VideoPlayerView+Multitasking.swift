import AVFoundation
import UIKit

/// Bookkeeping for the iPad multitasking pause — see `noteSystemPause`.
final class MultitaskPauseState {
    var systemPaused = false
    var lastUserPause: CFTimeInterval = 0
    var lastResume: CFTimeInterval = 0
    var resumeAttempts = 0
}

extension VideoPlayerView {
    /// The pause AVPlayer performs on reaching the end looks exactly like a
    /// system pause. Resuming there plays nothing and parks the player in
    /// `waitingToPlayAtSpecifiedRate` — a spinner that never clears.
    private var hasPlayedToEnd: Bool {
        guard let item = player?.currentItem,
              item.duration.isNumeric
        else {
            return false
        }
        let remaining = CMTimeGetSeconds(item.duration)
            - CMTimeGetSeconds(item.currentTime())
        return remaining < 0.5
    }

    /// Every rate change goes through here: the background rule first, then
    /// the multitasking resume.
    /// `observed` is the player the change came from, which a queued change
    /// can outlive as this view's `player` (rebuild, detach).
    func rateChanged(to rate: Float, of observed: AVPlayer) {
        if rate == 0, ScreenLockPause.shared.takePause(of: observed) {
            // A quick unlock can make the app active before this lands.
            showControlsIfPaused()
            return
        }
        if pauseIfPlayingInBackground(rate: rate) {
            return
        }
        noteSystemPause(rate: rate)
    }

    /// With background playback off, nothing may play while the app is in
    /// the background. The pause on entering it is not enough on its own:
    /// recovery, a rebuilt item, autoplay and the remote all call `play()`
    /// later, and with the screen locked that played audio nobody could see
    /// coming. Catching the rate change covers every one of them. PiP is
    /// the exception — that is the user watching.
    private func pauseIfPlayingInBackground(rate: Float) -> Bool {
        guard rate > 0,
              !BackgroundPlaybackService.isEnabled,
              !isPiPActive,
              UIApplication.shared.applicationState == .background else {
            return false
        }
        AppLog.player("playing in the background with background playback off, pausing")
        // The play being undone may be the multitasking resume; left set,
        // the flag would resume playback on the next activation.
        multitaskPause.systemPaused = false
        player?.pause()
        return true
    }

    /// A pause we did not ask for, while the app is on screen and active: iPad
    /// multitasking takes video away from an app the moment it stops being the
    /// frontmost one (dragged into Slide Over beside another app). Nothing
    /// reports it, and playing again right after is accepted — so that is what
    /// happens here, capped at two tries per 10s so we never fight the system.
    func noteSystemPause(rate: Float) {
        if rate > 0 {
            multitaskPause.systemPaused = false
            return
        }
        let now = CACurrentMediaTime()
        guard !isPiPActive,
              !hasPlayedToEnd,
              UIApplication.shared.applicationState == .active,
              now - multitaskPause.lastUserPause > 0.5
        else {
            return
        }
        if now - multitaskPause.lastResume > 10 {
            multitaskPause.resumeAttempts = 0
        }
        guard multitaskPause.resumeAttempts < 2 else {
            return
        }
        multitaskPause.systemPaused = true
        multitaskPause.resumeAttempts += 1
        multitaskPause.lastResume = now
        AppLog.player("paused while active — multitasking, resuming")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.resumeAfterSystemPause()
        }
    }

    /// A route that went away (headphone unplugged, Bluetooth disconnected)
    /// pauses playback, and it must stay paused: playing on the speaker is
    /// the one thing the pause is there to prevent. Marked as a user pause,
    /// which is what the resume above checks — and it is checked again after
    /// the delay, so the order of the two notifications does not matter.
    @objc
    func audioRouteChanged(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        else {
            return
        }
        multitaskPause.lastUserPause = CACurrentMediaTime()
    }

    /// On returning to a paused video the controls should be up: play is
    /// then one tap away, and the picture is clearly not frozen.
    func showControlsIfPaused() {
        guard let player, player.rate == 0, !isPiPActive,
              UIApplication.shared.applicationState == .active else {
            return
        }
        hideWorkItem?.cancel()
        setControls(visible: true, animated: true)
    }

    private func resumeAfterSystemPause() {
        guard let player, player.rate == 0, !isPiPActive,
              CACurrentMediaTime() - multitaskPause.lastUserPause > 0.5
        else {
            return
        }
        player.play()
    }
}
