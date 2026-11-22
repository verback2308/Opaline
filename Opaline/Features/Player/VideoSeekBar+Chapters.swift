import UIKit

// MARK: - Chapter Gaps

/// YouTube marks chapters by cutting short gaps into the track. The gaps sit
/// above the progress fill so they stay visible on the played part too.
extension VideoSeekBar {
    func configureChapterGaps() {
        chapterGapsView.backgroundColor = .clear
        chapterGapsView.isUserInteractionEnabled = false
    }

    /// Chapter starts in 0-1 range; a mark at 0 draws nothing.
    func setChapterMarks(_ marks: [Double]) {
        chapterMarks = marks.filter { $0 > 0 && $0 < 1 }
        chapterMarksLayoutWidth = -1
        setNeedsLayout()
    }

    /// Rebuilt only when the marks or the width change — `layoutSubviews`
    /// runs on every progress tick.
    func layoutChapterGaps() {
        chapterGapsView.frame = bounds
        let trackWidth = bounds.width
        guard trackWidth > 0, trackWidth != chapterMarksLayoutWidth else {
            return
        }
        chapterMarksLayoutWidth = trackWidth
        chapterGapsView.subviews.forEach { $0.removeFromSuperview() }
        let barY = (bounds.height - 4) / 2
        for mark in chapterMarks {
            let gap = UIView(
                frame: CGRect(
                    x: CGFloat(mark) * trackWidth - 1,
                    y: barY,
                    width: 2,
                    height: 4
                )
            )
            gap.backgroundColor = .black
            chapterGapsView.addSubview(gap)
        }
    }
}
