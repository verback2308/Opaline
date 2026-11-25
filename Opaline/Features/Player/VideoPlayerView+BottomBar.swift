import AVFoundation
import AVKit
import UIKit

// MARK: - Bottom Bar Setup

extension VideoPlayerView {
    func setupBottomBar() {
        setupTimeLabels()
        setupSeekBarCallbacks()
        setupFullscreenButton()
        addBottomBarSubviews()
        activateBottomBarConstraints()
    }

    private func setupTimeLabels() {
        let timeFont = UIFont.monospacedDigitSystemFont(
            ofSize: 12,
            weight: .medium
        )
        currentTimeLabel.font = timeFont
        currentTimeLabel.textColor = .white
        currentTimeLabel.text = "0:00"
        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = timeFont
        durationLabel.textColor = UIColor.white
            .withAlphaComponent(0.7)
        durationLabel.text = "0:00"
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupSeekBarCallbacks() {
        seekBar.translatesAutoresizingMaskIntoConstraints = false
        seekBar.onScrubStart = { [weak self] in
            self?.pauseAutoHide()
        }
        seekBar.onScrubEnd = { [weak self] progress in
            // No length yet (the next item is still loading): nothing to
            // measure the bar against, so a release would seek to 0.
            guard let self,
                  let currentPlayer = self.player, self.duration > 0
            else {
                return
            }
            let target = CMTime(
                seconds: progress * self.duration,
                preferredTimescale: 600
            )
            currentPlayer.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            // Scrubbing back from the end screen while paused leaves the
            // rate at 0, so the observer would not clear it.
            self.isAtEnd = false
            self.scheduleAutoHide()
        }
        seekBar.onScrubChanged = { [weak self] progress in
            guard let self else {
                return
            }
            self.currentTimeLabel.text = formatTime(
                progress * self.duration
            )
        }
    }

    private func setupFullscreenButton() {
        fullscreenButton.setImage(
            PlayerIcons.fullscreen(isFullscreen: false),
            for: .normal
        )
        fullscreenButton.tintColor = .white
        fullscreenButton.translatesAutoresizingMaskIntoConstraints = false
        fullscreenButton.addTarget(
            self,
            action: #selector(fullscreenTapped),
            for: .touchUpInside
        )
    }

    private func addBottomBarSubviews() {
        controlsView.addSubview(currentTimeLabel)
        controlsView.addSubview(seekBar)
        controlsView.addSubview(durationLabel)
        controlsView.addSubview(fullscreenButton)
    }

    private func activateBottomBarConstraints() {
        activateFullscreenConstraints()
        activateDurationConstraints()
        activateCurrentTimeConstraints()
        activateSeekBarConstraints()
    }

    private func activateFullscreenConstraints() {
        let safe = controlsView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            fullscreenButton.bottomAnchor.constraint(
                equalTo: safe.bottomAnchor,
                constant: -16
            ),
            fullscreenButton.trailingAnchor.constraint(
                equalTo: safe.trailingAnchor,
                constant: -16
            ),
            fullscreenButton.widthAnchor.constraint(
                equalToConstant: 36
            ),
            fullscreenButton.heightAnchor.constraint(
                equalToConstant: 36
            )
        ])
    }

    private func activateDurationConstraints() {
        NSLayoutConstraint.activate([
            durationLabel.centerYAnchor.constraint(
                equalTo: fullscreenButton.centerYAnchor
            ),
            durationLabel.trailingAnchor.constraint(
                equalTo: fullscreenButton.leadingAnchor,
                constant: -8
            )
        ])
    }

    private func activateCurrentTimeConstraints() {
        let safe = controlsView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            currentTimeLabel.centerYAnchor.constraint(
                equalTo: fullscreenButton.centerYAnchor
            ),
            currentTimeLabel.leadingAnchor.constraint(
                equalTo: safe.leadingAnchor,
                constant: 28
            )
        ])
    }

    private func activateSeekBarConstraints() {
        let safe = controlsView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            seekBar.leadingAnchor.constraint(
                equalTo: safe.leadingAnchor,
                constant: 28
            ),
            seekBar.trailingAnchor.constraint(
                equalTo: safe.trailingAnchor,
                constant: -16
            ),
            // Sit just above the time labels, not above the (much taller)
            // fullscreen button — otherwise the bar rides ~18pt high, which on
            // a short player (Slide Over) puts it right under the transport
            // buttons while leaving a wide gap down to the timestamps.
            seekBar.bottomAnchor.constraint(
                equalTo: currentTimeLabel.topAnchor,
                constant: -4
            ),
            seekBar.heightAnchor.constraint(
                equalToConstant: 20
            )
        ])
    }
}

// MARK: - Helpers

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else {
        return "0:00"
    }
    let totalSeconds = Int(seconds)
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let secs = totalSeconds % 60
    if hours > 0 {
        return String(
            format: "%d:%02d:%02d",
            hours,
            minutes,
            secs
        )
    }
    return String(
        format: "%d:%02d",
        minutes,
        secs
    )
}
