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
            chapterButton.heightAnchor.constraint(equalToConstant: 32)
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
        guard let index = VideoChapter.index(at: seconds, in: chapters) else {
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
