import UIKit

// MARK: - Chapters

/// The current chapter's title sits after the elapsed time, as in YouTube's
/// player; tapping it opens the chapter list. The seek bar shows a gap at
/// every chapter start.
extension VideoPlayerView {
    func setupChapterButton() {
        chapterButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        chapterButton.titleLabel?.lineBreakMode = .byTruncatingTail
        chapterButton.setTitleColor(.white, for: .normal)
        chapterButton.contentHorizontalAlignment = .leading
        chapterButton.isHidden = true
        chapterButton.translatesAutoresizingMaskIntoConstraints = false
        // A long title gives way, never the times beside it.
        chapterButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [currentTimeLabel, durationLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        chapterButton.addTarget(
            self,
            action: #selector(chapterButtonTapped),
            for: .touchUpInside
        )
        controlsView.addSubview(chapterButton)
        NSLayoutConstraint.activate([
            chapterButton.centerYAnchor.constraint(
                equalTo: currentTimeLabel.centerYAnchor
            ),
            chapterButton.leadingAnchor.constraint(
                equalTo: currentTimeLabel.trailingAnchor,
                constant: 6
            ),
            chapterButton.trailingAnchor.constraint(
                lessThanOrEqualTo: durationLabel.leadingAnchor,
                constant: -12
            ),
            // No taller than this: the seek bar's touch band ends 4pt above
            // the time label, and anything higher would sit on top of it.
            chapterButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    func setChapters(_ newChapters: [VideoChapter]) {
        guard newChapters != chapters else {
            return
        }
        chapters = newChapters
        chapterButton.isHidden = chapters.isEmpty
        refreshChapterMarks()
        let seconds = player.map { $0.currentTime().seconds } ?? 0
        updateChapterTitle(at: seconds.isFinite ? seconds : 0)
    }

    /// Called whenever the duration becomes known: both the SponsorBlock
    /// segments and the chapter gaps are stored as fractions of it.
    func refreshSeekBarMarks() {
        refreshSponsorSeekBar()
        refreshChapterMarks()
    }

    func setSeekBarProgress(seconds: Double) {
        seekBar.setProgress(seconds / duration)
        updateChapterTitle(at: seconds)
    }

    func updateChapterTitle(at seconds: Double) {
        let index = VideoChapter.index(at: seconds, in: chapters)
        // Before the first chapter starts there is nothing to name.
        chapterButton.isHidden = index == nil
        guard let index else {
            chapterButton.setTitle(nil, for: .normal)
            return
        }
        let title = "\u{2022} \(chapters[index].title) \u{203A}"
        if chapterButton.title(for: .normal) != title {
            UIView.performWithoutAnimation {
                chapterButton.setTitle(title, for: .normal)
                chapterButton.layoutIfNeeded()
            }
        }
    }

    private func refreshChapterMarks() {
        guard duration > 0 else {
            seekBar.setChapterMarks([])
            return
        }
        seekBar.setChapterMarks(chapters.map { $0.start / duration })
    }

    @objc
    private func chapterButtonTapped() {
        onChaptersTapped?()
        scheduleAutoHide()
    }
}
