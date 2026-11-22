import AVFoundation
import AVKit
import UIKit

// MARK: - Gesture Handling

extension VideoPlayerView {
    @objc
    func handleTap() {
        if controlsVisible {
            setControls(visible: false, animated: true)
        } else {
            setControls(visible: true, animated: true)
            scheduleAutoHide()
        }
    }

    @objc
    func handleDoubleTap(
        _ gesture: UITapGestureRecognizer
    ) {
        // Straight to the seek, not through the buttons: those now switch
        // videos, and the gesture is the only way to seek by steps.
        let zone = seekZone(atX: gesture.location(in: self).x)
        flashSeekZone(zone)
        switch zone {
        case .rewind:
            seek(direction: -1)
        case .forward:
            seek(direction: 1)
        case .playPause:
            playPauseTapped()
        }
        // The overlay stays as it was: a double tap that pulls it up covers
        // the video the user is seeking through, and on the middle zone it
        // put the controls over a pause the icon already shows (#107).
        if controlsVisible {
            scheduleAutoHide()
        }
    }

    @objc
    func handlePinch(
        _ gesture: UIPinchGestureRecognizer
    ) {
        if isFullscreen {
            handleFullscreenPinch(gesture)
            return
        }
        guard gesture.state == .ended else {
            return
        }
        if gesture.scale > 1.2 {
            delegate?.videoPlayerViewDidTapFullscreen(self)
        }
    }
}

extension CGFloat {
    /// The hidden controls overlay stays a whisper above transparent instead
    /// of fully invisible. At alpha 0 nothing is composited over the video
    /// and the layer is handed to the display's video plane, which bypasses
    /// the accessibility display filters — Reduce White Point, Night Shift
    /// and True Tone stop applying to the picture until an overlay comes
    /// back. Below 0.01 UIKit still skips hit-testing, so taps reach the
    /// player's gestures exactly as before.
    static let hiddenControlsAlpha: CGFloat = 0.005
}

// MARK: - Controls Visibility

extension VideoPlayerView {
    func setControls(visible: Bool, animated: Bool) {
        controlsVisible = visible
        // `updateProgress` skips the seek bar while the overlay is hidden,
        // so catch it up before it comes back into view.
        if visible, let time = player?.currentTime() {
            updateProgress(time: time)
        }
        let targetAlpha: CGFloat = visible ? 1 : .hiddenControlsAlpha
        let animDuration = animated ? 0.2 : 0
        UIView.animate(withDuration: animDuration) {
            self.controlsView.alpha = targetAlpha
            self.topGradientLayer.opacity = visible
                ? 1
                : 0
            self.bottomGradientLayer.opacity = visible
                ? 1
                : 0
        }
        if !visible {
            speedOverlay.isHidden = true
        }
    }

    func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.player?.rate ?? 0 > 0
            else {
                return
            }
            self.setControls(
                visible: false,
                animated: true
            )
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 3,
            execute: item
        )
    }

    func pauseAutoHide() {
        hideWorkItem?.cancel()
    }
}

// MARK: - Button Actions

extension VideoPlayerView {
    @objc
    func playPauseTapped() {
        guard let player else {
            return
        }
        if isAtEnd {
            replay()
            return
        }
        if player.rate > 0 {
            multitaskPause.lastUserPause = CACurrentMediaTime()
            player.pause()
        } else {
            player.play()
        }
        scheduleAutoHide()
    }

    // Seeking lives on the double-tap gesture, as in the official app.
    @objc
    func rewindTapped() {
        if hasPreviousVideo { onPrevious?() }
    }

    @objc
    func forwardTapped() {
        onNext?()
    }

    @objc
    func skipButtonTapped() {
        onSkipTapped?()
    }

    @objc
    func settingsTapped() {
        delegate?.videoPlayerViewDidTapSettings(self)
        scheduleAutoHide()
    }

    @objc
    func fullscreenTapped() {
        delegate?.videoPlayerViewDidTapFullscreen(self)
    }
}

/// Tracks a burst of consecutive same-direction seek taps.
final class SeekBurstState {
    var direction = 0
    var tapCount = 0
    var accumulated: Double = 0
    var lastTap: CFTimeInterval = 0
    /// Position the last tap of this burst asked for. Seeks are async, so
    /// `player.currentTime()` still reports the old playhead when taps come
    /// faster than a seek completes — chaining off the requested target
    /// instead is what makes a burst actually add up.
    var target: CMTime = .invalid
}

// MARK: - Accelerating Seek
//
// Consecutive same-direction taps within `seekBurstWindow` (1.2s — longer
// than a normal tap cadence, short enough that it never spans two separate
// seek intents) accumulate into a growing step. The per-tap ladder is
// 10 / 20 / 30s for the first three taps of a burst (so 3 taps ≈ 60s,
// matching "roughly 3-4 taps get you about a minute"), then flat 60s per
// tap after that — capped so a long hold-on burst stays fast but
// controllable rather than exploding. An opposite-direction tap, or one
// that arrives after the window has elapsed, resets the burst.
extension VideoPlayerView {
    private static let seekBurstWindow: CFTimeInterval = 1.2
    private static let seekStepLadder: [Double] = [10, 20, 30]
    private static let seekStepCap: Double = 60

    private func seekStep(forTapIndex index: Int) -> Double {
        if index >= 1, index <= Self.seekStepLadder.count {
            return Self.seekStepLadder[index - 1]
        }
        return Self.seekStepCap
    }

    private func seek(direction: Int) {
        guard let player else {
            return
        }
        let now = CACurrentMediaTime()
        if direction == seekBurst.direction,
           now - seekBurst.lastTap < Self.seekBurstWindow {
            seekBurst.tapCount += 1
        } else {
            seekBurst.direction = direction
            seekBurst.tapCount = 1
            seekBurst.accumulated = 0
            seekBurst.target = .invalid
        }
        seekBurst.lastTap = now
        let step = seekStep(forTapIndex: seekBurst.tapCount)
        seekBurst.accumulated += step

        let offset = CMTime(seconds: step, preferredTimescale: 600)
        let base = seekBurst.target.isNumeric
            ? seekBurst.target
            : player.currentTime()
        let proposed = direction > 0 ? base + offset : base - offset
        let destination = clampedSeekTime(proposed)
        seekBurst.target = destination
        player.seek(
            to: destination,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        showSeekHUD(totalOffset: seekBurst.accumulated * Double(direction))
        scheduleAutoHide()
    }

    private func clampedSeekTime(_ time: CMTime) -> CMTime {
        if time < .zero {
            return .zero
        }
        if duration > 0 {
            let end = CMTime(seconds: duration, preferredTimescale: 600)
            if time > end {
                return end
            }
        }
        return time
    }

    private func showSeekHUD(totalOffset: Double) {
        let sign = totalOffset >= 0 ? "+" : "-"
        let seconds = Int(abs(totalOffset).rounded())
        let text = "player.seek.offset".localized(
            with: "\(sign)\(seconds)"
        )
        showHUD(text: "  \(text)  ")
        hideHUD(after: 0.8)
    }
}

// MARK: - Icon Updates

extension VideoPlayerView {
    func updatePlayPauseIcon() {
        if isAtEnd {
            playPauseButton.setImage(PlayerIcons.replay(), for: .normal)
            return
        }
        let isPlaying = (player?.rate ?? 0) > 0
        let icon = isPlaying
            ? PlayerIcons.pause()
            : PlayerIcons.play()
        playPauseButton.setImage(icon, for: .normal)
    }

    func updateFullscreenIcon() {
        fullscreenButton.setImage(
            PlayerIcons.fullscreen(
                isFullscreen: isFullscreen
            ),
            for: .normal
        )
    }
}
