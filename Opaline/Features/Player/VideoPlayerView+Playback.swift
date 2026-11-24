import AVFoundation
import AVKit
import UIKit

/// State for the stall-recovery clock resync (issue #14).
final class ClockResyncState {
    var isStalled = false
    var workItem: DispatchWorkItem?
    var lastResync: CFTimeInterval = 0
}

// MARK: - Playback API

extension VideoPlayerView {
    func attach(player newPlayer: AVPlayer) {
        player = newPlayer
        playerLayer.isHidden = false
        playerLayer.player = newPlayer
        addPeriodicObserver()
        addPlayerObservers()
        updatePlayPauseIcon()
        setupPiP()
        // The speed is applied by whoever starts playback
        // (`playImmediately(atRate:)`); setting it here as a rate started a
        // player meant to stay paused.
    }

    /// Rebinds observers after the host replaced the item on the SAME
    /// player (background video-to-video transition): the duration KVO
    /// watches `currentItem`, so it must re-attach to the new one. The
    /// layer is deliberately untouched — it stays detached while
    /// backgrounded and comes back on activation.
    func rebind(player newPlayer: AVPlayer) {
        player = newPlayer
        removePlayerObservers()
        addPlayerObservers()
        duration = 0
    }

    func detach() {
        removePeriodicObserver()
        removePlayerObservers()
        clockResync.isStalled = false
        clockResync.workItem?.cancel()
        clockResync.workItem = nil
        playerLayer.isHidden = false
        playerLayer.player = nil
        player = nil
        hideSkipButton()
        sponsorSegments = []
        seekBar.setSegments([])
        seekBar.cancelScrubbing()
        speedOverlay.isHidden = true
        hudWorkItem?.cancel()
        hudLabel.alpha = 0
        seekBurst.direction = 0
        seekBurst.tapCount = 0
        seekBurst.accumulated = 0
        seekBurst.target = .invalid
    }

    func setSponsorSegments(
        _ segments: [SponsorBlockSegment]
    ) {
        sponsorSegments = segments
        refreshSponsorSeekBar()
    }

    func showSkipButton(categoryName: String) {
        skipButton.setTitle(
            "sponsorblock.skip".localized(with: categoryName),
            for: .normal
        )
        skipButton.isHidden = false
    }

    func hideSkipButton() {
        skipButton.isHidden = true
    }

    func refreshSponsorSeekBar() {
        guard duration > 0 else {
            return
        }
        let normalized = sponsorSegments
            .filter {
                SponsorBlockService.skipBehavior(
                    for: $0.category
                ) != .disabled
            }
            .map {
                SeekBarSegment(
                    start: $0.startTime / duration,
                    end: $0.endTime / duration,
                    color: $0.category.seekBarColor
                )
            }
        seekBar.setSegments(normalized)
    }

    // MARK: - Periodic Observer

    func addPeriodicObserver() {
        guard let player else {
            return
        }
        let interval = CMTime(
            seconds: 0.1,
            preferredTimescale: 600
        )
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.updateProgress(time: time)
        }
    }

    func removePeriodicObserver() {
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }
    }

    // MARK: - Player Observers

    func addPlayerObservers() {
        guard let player else {
            return
        }
        observeRate(on: player)
        observeTimeControl(on: player)
        observeDuration(on: player)
    }

    private func observeRate(on player: AVPlayer) {
        rateObservation = player.observe(
            \.rate,
            options: [.new]
        ) { [weak self] observed, _ in
            DispatchQueue.main.async {
                self?.noteSystemPause(rate: observed.rate)
                if observed.rate > 0 { self?.isAtEnd = false }
                self?.updatePlayPauseIcon()
            }
        }
    }

    private func observeTimeControl(on player: AVPlayer) {
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] observed, _ in
            DispatchQueue.main.async {
                self?.handleTimeControlChange(on: observed)
            }
        }
    }

    private func handleTimeControlChange(on player: AVPlayer) {
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            scheduleBufferingIndicator()
            if CMTimeGetSeconds(player.currentTime()) > 1 {
                clockResync.isStalled = true
            }
        case .playing:
            hideBufferingIndicator()
            if clockResync.isStalled {
                clockResync.isStalled = false
                scheduleClockResync()
            }
        case .paused:
            hideBufferingIndicator()
            clockResync.isStalled = false
            clockResync.workItem?.cancel()
        @unknown default:
            break
        }
    }

    // MARK: - Stall Clock Resync

    /// A frame-accurate seek to the current position snaps the
    /// player clock back to the rendered media. Only runs while
    /// subtitles are active — nothing else is precise enough to
    /// notice the drift, and the seek costs a brief hiccup.
    private func scheduleClockResync() {
        guard !subtitleCues.isEmpty else {
            return
        }
        clockResync.workItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performClockResync()
        }
        clockResync.workItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0,
            execute: work
        )
    }

    private func performClockResync() {
        guard let player,
              player.timeControlStatus == .playing else {
            return
        }
        let now = CACurrentMediaTime()
        guard now - clockResync.lastResync > 10 else {
            return
        }
        clockResync.lastResync = now
        let time = player.currentTime()
        AppLog.player(
            "clock resync after stall at "
                + String(
                    format: "%.1fs",
                    CMTimeGetSeconds(time)
                )
        )
        player.seek(
            to: time,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// `.initial`: a local file already knows its duration, so a
    /// change-only observer never fires and the bar stays at 0:00.
    private func observeDuration(on player: AVPlayer) {
        statusObservation = player.currentItem?.observe(
            \.duration, options: [.initial, .new]
        ) { [weak self] item, _ in
            DispatchQueue.main.async {
                let secs = CMTimeGetSeconds(item.duration)
                if secs.isFinite, secs > 0 {
                    self?.duration = secs
                    self?.durationLabel.text = formatTime(
                        secs
                    )
                    self?.refreshSponsorSeekBar()
                }
            }
        }
    }

    func removePlayerObservers() {
        rateObservation = nil
        statusObservation = nil
        timeControlObservation = nil
    }

    // MARK: - Progress

    func updateProgress(time: CMTime) {
        guard duration > 0 else {
            return
        }
        let secs = CMTimeGetSeconds(time)
        // The overlay is hidden most of the time, and while it is there is
        // nothing to redraw — but the observer still ticks 10x/sec to drive
        // SponsorBlock, subtitles and watchtime through `onTimeUpdate`, so
        // only the seek bar work is skipped.
        //
        // While the user drags the thumb, `onScrubChanged` owns the label
        // and the bar's fill/thumb — the periodic observer must not fight
        // the finger with the actual playback position (issue: label was
        // unreadable mid-scrub).
        if controlsVisible, !seekBar.isScrubbing {
            // This string changes once a second; assigning it every tick
            // invalidates the label's intrinsic size and relays out the
            // whole bottom bar.
            let stamp = formatTime(secs)
            if currentTimeLabel.text != stamp {
                currentTimeLabel.text = stamp
            }
            seekBar.setProgress(secs / duration)
            updateBuffer(at: time)
        }
        onTimeUpdate?(secs)
    }

    private func updateBuffer(at time: CMTime) {
        guard let item = player?.currentItem else {
            return
        }
        let buffered = item.loadedTimeRanges
            .compactMap { $0 as? CMTimeRange }
            .filter {
                CMTimeRangeContainsTime($0, time: time)
            }
            .map {
                CMTimeGetSeconds($0.start)
                    + CMTimeGetSeconds($0.duration)
            }
            .max() ?? 0
        seekBar.setBuffer(buffered / duration)
    }
}
