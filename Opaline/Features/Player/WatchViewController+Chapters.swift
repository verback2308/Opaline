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
                self?.seekPlayer(toSeconds: Int(chapter.start))
            }
        }
        presentPlayerMenu(
            title: "player.menu.chapters".localized, items: items
        )
    }
}
