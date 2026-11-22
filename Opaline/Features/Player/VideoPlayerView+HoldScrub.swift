import AVFoundation
import UIKit

/// Where the finger went down and what the playhead was at that moment.
final class HoldScrubState {
    /// The finger is down and past the press duration, but has not travelled
    /// far enough to mean a scrub yet.
    var isTracking = false
    var isActive = false
    var startX: CGFloat = 0
    var startProgress: Double = 0
}

/// A press that never travels this far is a press, not a drag. Below it the
/// bar is never touched, so lifting the finger cannot seek.
private let holdScrubThreshold: CGFloat = 8

/// Press and hold anywhere on the picture to play at 2x while the finger
/// stays down (#149), or drag sideways to scrub instead (#116). The seek
/// bar is a thin target and the finger covers the video while dragging it,
/// so the whole surface acts as the track.
///
/// The gesture does not seek by itself: it drives the seek bar through the
/// same three steps a finger on the track does, so the thumb, the time
/// label, the suspended progress ticks and the final seek are the ones the
/// bar already owns. Sideways travel maps the same way too — the full
/// player width is the whole video, measured from wherever playback stood
/// when the press landed.
extension VideoPlayerView {
    /// Taps must wait for the hold to fail, or a press held past
    /// `minimumPressDuration` would also toggle the controls on lift-up.
    /// A quick tap fails the hold the moment the finger leaves, so nothing
    /// waits the extra third of a second.
    func addHoldScrubGesture(blocking taps: [UIGestureRecognizer]) {
        let hold = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleHoldScrub(_:))
        )
        hold.minimumPressDuration = 0.35
        // A press on a control belongs to that control — see
        // `gestureRecognizer(_:shouldReceive:)`.
        hold.delegate = self
        addGestureRecognizer(hold)
        taps.forEach { $0.require(toFail: hold) }
    }

    /// Nothing else on the player may start while it is held (2x or a
    /// drag): a downward flick that is really the tail of a scrub used to
    /// throw fullscreen away, and a second finger used to pinch-zoom.
    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if holdScrub.isTracking {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc
    func handleHoldScrub(
        _ gesture: UILongPressGestureRecognizer
    ) {
        switch gesture.state {
        case .began:
            beginHoldScrub(atX: gesture.location(in: self).x)
        case .changed:
            updateHoldScrub(atX: gesture.location(in: self).x)
        case .ended, .cancelled, .failed:
            endHoldScrub()
        default:
            break
        }
    }

    /// Arms the drag without starting it: a press that never moves must not
    /// seek, and `onScrubEnd` seeks with zero tolerance, which is a visible
    /// stall on generated HLS even when the target is where playback already
    /// stands.
    private func beginHoldScrub(atX xPosition: CGFloat) {
        guard duration > 0,
              let time = player?.currentTime()
        else {
            return
        }
        holdScrub.isTracking = true
        holdScrub.startX = xPosition
        holdScrub.startProgress = CMTimeGetSeconds(time) / duration
        startSpeedBoost()
    }

    private func updateHoldScrub(atX xPosition: CGFloat) {
        guard holdScrub.isTracking, bounds.width > 0 else {
            return
        }
        if !holdScrub.isActive {
            guard abs(xPosition - holdScrub.startX) >= holdScrubThreshold else {
                return
            }
            beginDragScrub(atX: xPosition)
        }
        seekBar.updateExternalScrub(
            to: holdScrub.startProgress
                + Double((xPosition - holdScrub.startX) / bounds.width)
        )
    }

    private func endHoldScrub() {
        holdScrub.isTracking = false
        stopSpeedBoost()
        guard holdScrub.isActive else {
            return
        }
        holdScrub.isActive = false
        seekBar.endExternalScrub()
    }
}

// MARK: - Hold for 2x

extension VideoPlayerView {
    /// A drag is a scrub, not a fast-forward: back to the chosen speed, the
    /// bar and time label up as the readout, and measured from where
    /// playback is now — a 2x hold has moved it on since the press landed.
    private func beginDragScrub(atX xPosition: CGFloat) {
        holdScrub.isActive = true
        stopSpeedBoost()
        if let time = player?.currentTime(), duration > 0 {
            holdScrub.startProgress = CMTimeGetSeconds(time) / duration
        }
        holdScrub.startX = xPosition
        if !controlsVisible {
            setControls(visible: true, animated: true)
        }
        seekBar.beginExternalScrub()
    }

    /// Only a playing video speeds up: a press on a paused one is the start
    /// of a scrub, and starting playback from a hold would surprise.
    private func startSpeedBoost() {
        guard let player else {
            return
        }
        speedBoost.badge.install(in: self)
        _ = speedBoost.begin(player, rate: max(playbackSpeed, SpeedBoostBadge.boostedRate))
    }

    /// Back to the speed the user picked.
    private func stopSpeedBoost() {
        speedBoost.end(player, restoring: playbackSpeed)
    }
}
