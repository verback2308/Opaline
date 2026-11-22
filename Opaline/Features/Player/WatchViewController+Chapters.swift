import AVFoundation
import UIKit

// MARK: - Chapters

extension WatchViewController {
    /// Hands the current page's chapters to the player. Runs when the page
    /// arrives, when a new player view is created and when the screen is
    /// reset for the next video — whichever comes last wins.
    func applyChapters() {
        guard let playerView = videoPlayerView else {
            return
        }
        playerView.setChapters(watchPage?.chapters ?? [])
        playerView.onChaptersTapped = { [weak self] in
            self?.showChapterPicker()
        }
    }

    func showChapterPicker() {
        let chapters = watchPage?.chapters ?? []
        guard !chapters.isEmpty else {
            return
        }
        let seconds = videoPlayerView?.player?.currentTime().seconds ?? 0
        let current = VideoChapter.index(
            at: seconds.isFinite ? seconds : 0, in: chapters
        )
        let items = chapters.enumerated().map { index, chapter in
            let marker = index == current ? "\u{25B6}\u{FE0E} " : ""
            return PlayerMenuItem(
                title: "\(marker)\(formatTime(chapter.start))  \(chapter.title)"
            ) { [weak self] in
                self?.seekToChapter(chapter)
            }
        }
        presentPlayerMenu(
            title: "player.menu.chapters".localized, items: items
        )
    }

    /// To the exact start: rounding down to the second can land just inside
    /// the chapter before, which would then show as the current one.
    private func seekToChapter(_ chapter: VideoChapter) {
        videoPlayerView?.player?.seek(
            to: CMTime(seconds: chapter.start, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
