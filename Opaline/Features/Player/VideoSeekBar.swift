import UIKit

final class VideoSeekBar: UIControl {
    var onScrubStart: (() -> Void)?
    var onScrubEnd: ((Double) -> Void)?
    var onScrubChanged: ((Double) -> Void)?

    private(set) var isScrubbing = false

    private let trackView    = UIView()
    private let bufferView   = UIView()
    private let segmentsView = UIView()
    private let progressView = UIView()
    private let thumbView    = UIView()

    private var progress: Double = 0
    private var buffer: Double   = 0
    private var segments: [SeekBarSegment] = []
    /// Track width the segment bars were last built for, or -1 when the
    /// segment list changed. `layoutSubviews` runs 10x/sec off `setProgress`,
    /// but the bars only depend on the segments and the width — rebuilding
    /// them every tick meant creating and destroying a UIView per segment
    /// forever, even with the controls overlay hidden.
    private var segmentsLayoutWidth: CGFloat = -1
    let chapterGapsView = UIView()
    var chapterMarks: [Double] = [], chapterMarksLayoutWidth: CGFloat = -1
    private var bufferWidthConstraint: NSLayoutConstraint?
    private var progressWidthConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        let pan = UIPanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTrackTap(_:))
        )
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let trackWidth = bounds.width
        let barY = (bounds.height - 4) / 2
        bufferView.frame = CGRect(
            x: 0,
            y: barY,
            width: trackWidth * CGFloat(buffer),
            height: 4
        )
        progressView.frame = CGRect(
            x: 0,
            y: barY,
            width: trackWidth * CGFloat(progress),
            height: 4
        )
        thumbView.center = CGPoint(
            x: trackWidth * CGFloat(progress),
            y: bounds.height / 2
        )
        layoutSegmentViews()
        layoutChapterGaps()
    }

    func setProgress(_ value: Double) {
        progress = max(0, min(1, value))
        setNeedsLayout()
    }

    func setBuffer(_ value: Double) {
        buffer = max(0, min(1, value))
        setNeedsLayout()
    }

    /// Sets the SponsorBlock segment markers in 0-1 range.
    func setSegments(_ newSegments: [SeekBarSegment]) {
        segments = newSegments
        segmentsLayoutWidth = -1
        setNeedsLayout()
    }

    @objc
    private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let px = gesture.location(in: self).x
        let pct = max(0, min(1, Double(px / bounds.width)))

        switch gesture.state {
        case .began:
            startScrubVisuals()
            onScrubStart?()
        case .changed:
            progress = pct
            setNeedsLayout()
            onScrubChanged?(pct)
        case .ended, .cancelled:
            endScrubVisuals()
            onScrubEnd?(pct)
        default:
            break
        }
    }

    private func startScrubVisuals() {
        isScrubbing = true
        thumbView.isHidden = false
        UIView.animate(withDuration: 0.15) {
            self.thumbView.transform = CGAffineTransform(
                scaleX: 1.3, y: 1.3
            )
        }
    }

    private func endScrubVisuals() {
        UIView.animate(withDuration: 0.15) {
            self.thumbView.transform = .identity
        }
        thumbView.isHidden = true
        isScrubbing = false
    }

    private func setupViews() {
        configureTrackViews()
        addTrackSubviews()
        activateTrackConstraints()
    }

    private func configureTrackViews() {
        trackView.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        trackView.layer.cornerRadius = 2
        trackView.clipsToBounds = true
        trackView.translatesAutoresizingMaskIntoConstraints = false

        bufferView.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        bufferView.layer.cornerRadius = 2
        bufferView.translatesAutoresizingMaskIntoConstraints = false

        segmentsView.backgroundColor = .clear
        segmentsView.translatesAutoresizingMaskIntoConstraints = false
        segmentsView.isUserInteractionEnabled = false

        progressView.backgroundColor = .white
        progressView.layer.cornerRadius = 2
        progressView.translatesAutoresizingMaskIntoConstraints = false

        thumbView.backgroundColor = .white
        thumbView.layer.cornerRadius = 6
        thumbView.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        thumbView.isHidden = true
        configureChapterGaps()
    }

    private func addTrackSubviews() {
        addSubview(trackView)
        addSubview(bufferView)
        addSubview(segmentsView)
        addSubview(progressView)
        addSubview(chapterGapsView)
        addSubview(thumbView)
    }

    private func activateTrackConstraints() {
        NSLayoutConstraint.activate([
            trackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            trackView.heightAnchor.constraint(equalToConstant: 4),

            bufferView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bufferView.centerYAnchor.constraint(equalTo: centerYAnchor),
            bufferView.heightAnchor.constraint(equalToConstant: 4),

            segmentsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            segmentsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            segmentsView.centerYAnchor.constraint(equalTo: centerYAnchor),
            segmentsView.heightAnchor.constraint(equalToConstant: 4),

            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 4)
        ])
    }

    private func layoutSegmentViews() {
        let trackWidth = segmentsView.bounds.width
        guard trackWidth > 0, trackWidth != segmentsLayoutWidth else {
            return
        }
        segmentsLayoutWidth = trackWidth
        segmentsView.subviews.forEach { $0.removeFromSuperview() }
        for seg in segments {
            let segX = CGFloat(seg.start) * trackWidth
            let segW = max(
                2,
                CGFloat(seg.end - seg.start) * trackWidth
            )
            let bar = UIView(
                frame: CGRect(
                    x: segX,
                    y: 0,
                    width: segW,
                    height: 4
                )
            )
            bar.backgroundColor = seg.color
            segmentsView.addSubview(bar)
        }
    }
}

extension VideoSeekBar {
    // MARK: - Driven From Outside

    /// The hold-anywhere scrub on the player surface (#116) runs the bar
    /// through the same three steps a finger on the track does, so the
    /// thumb, the paused progress ticks and the final seek stay in one
    /// place instead of being written a second time against the player.
    func beginExternalScrub() {
        guard !isScrubbing else {
            return
        }
        startScrubVisuals()
        onScrubStart?()
    }

    func updateExternalScrub(to value: Double) {
        guard isScrubbing else {
            return
        }
        progress = max(0, min(1, value))
        setNeedsLayout()
        onScrubChanged?(progress)
    }

    func endExternalScrub() {
        guard isScrubbing else {
            return
        }
        endScrubVisuals()
        onScrubEnd?(progress)
    }

    /// Force-clears a stuck drag (e.g. the player detaches mid-scrub).
    /// Does not fire `onScrubEnd` — there is no target to seek to.
    func cancelScrubbing() {
        guard isScrubbing else {
            return
        }
        endScrubVisuals()
    }

    @objc
    private func handleTrackTap(
        _ gesture: UITapGestureRecognizer
    ) {
        let px = gesture.location(in: self).x
        let pct = max(0, min(1, Double(px / bounds.width)))
        progress = pct
        setNeedsLayout()
        onScrubEnd?(pct)
    }
}

struct SeekBarSegment {
    let start: Double
    let end: Double
    let color: UIColor
}
