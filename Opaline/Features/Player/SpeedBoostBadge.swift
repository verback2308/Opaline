import UIKit

/// The "2x" pill shown while a press holds playback at double speed, as in
/// the official app. Text only, so it draws the same on iOS 12.
final class SpeedBoostBadge: UIView {
    static let boostedRate: Float = 2

    private let label = UILabel()
    private var wantsVisible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        layer.cornerRadius = 15
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0
        translatesAutoresizingMaskIntoConstraints = false
        label.text = "2x \u{25B6}\u{FE0E}\u{25B6}\u{FE0E}"
        label.font = .boldSystemFont(ofSize: 13)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Pins the badge to the top centre of `host`, below its safe area.
    func install(in host: UIView) {
        guard superview !== host else {
            host.bringSubviewToFront(self)
            return
        }
        removeFromSuperview()
        host.addSubview(self)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            topAnchor.constraint(
                equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 16
            )
        ])
    }

    func setVisible(_ visible: Bool) {
        guard visible != wantsVisible else {
            return
        }
        wantsVisible = visible
        if visible {
            isHidden = false
        }
        let fade = { self.alpha = visible ? 1 : 0 }
        // Hidden only once faded, and only if nothing showed it since.
        UIView.animate(withDuration: 0.15, animations: fade) { _ in
            self.isHidden = !self.wantsVisible
        }
    }
}
