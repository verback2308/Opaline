import AVFoundation
import UIKit

// MARK: - Buffering indicator

extension VideoPlayerView {
    /// AVPlayer passes through `waitingToPlayAtSpecifiedRate` on nearly every
    /// `play()`, buffered or not — showing the spinner (and hiding the
    /// transport buttons) right then makes a resume flicker like a stall.
    /// Only a wait that outlives the grace period is a real one.
    func scheduleBufferingIndicator() {
        bufferingIndicatorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
                return
            }
            self.spinner.startAnimating()
            self.setCenter(hidden: true)
        }
        bufferingIndicatorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func hideBufferingIndicator() {
        bufferingIndicatorWork?.cancel()
        // The resume seek owns the spinner until the picture is back.
        guard !isResumeSeeking else {
            return
        }
        spinner.stopAnimating()
        setCenter(hidden: false)
    }
}

// MARK: - Resume seek

extension VideoPlayerView {
    /// Before the item is ready, and while the resume seek runs, its time is
    /// a placeholder 0 rather than where playback is: the clock keeps what
    /// `showClock` put there.
    var showsItemTime: Bool {
        !isResumeSeeking && player?.currentItem?.status == .readyToPlay
    }

    /// Covers the stretch between the item turning ready at its start and
    /// the seek to the saved position landing — seconds on a slow stream.
    /// The picture stays hidden behind the spinner and the clock already
    /// reads the resume time, so the opening frame and 0:00 never show.
    func beginResumeSeek(to seconds: Double) {
        isResumeSeeking = true
        playerLayer.isHidden = true
        bufferingIndicatorWork?.cancel()
        spinner.startAnimating()
        setCenter(hidden: true)
        showClock(at: seconds)
    }

    /// Puts the clock on where playback is about to start, before the item
    /// reports any time of its own.
    func showClock(at seconds: Double) {
        currentTimeLabel.text = formatTime(seconds)
        if duration > 0 {
            seekBar.setProgress(seconds / duration)
        }
    }

    func endResumeSeek() {
        guard isResumeSeeking else {
            return
        }
        isResumeSeeking = false
        playerLayer.isHidden = false
        if player?.timeControlStatus != .waitingToPlayAtSpecifiedRate {
            hideBufferingIndicator()
        }
    }
}
