import UIKit

/// Transient confirmation strip. iPads have no Taptic Engine, so a visible
/// toast — not haptics — is the only feedback that works on every device.
enum ToastView {
    /// A toast always confirms (or fails) an action that just finished, so
    /// the matching notification haptic belongs here rather than at every
    /// call site.
    static func show(
        _ text: String,
        in view: UIView,
        isError: Bool = false,
        bottomInset: CGFloat = 32
    ) {
        if isError {
            Feedback.failure()
        } else {
            Feedback.success()
        }
        let label = makeLabel(text)
        view.addSubview(label)
        pin(label, to: view, bottomInset: bottomInset)
        UIView.animate(withDuration: 0.2) {
            label.alpha = 1
        }
        UIView.animate(
            withDuration: 0.3,
            delay: 1.6,
            options: [],
            animations: { label.alpha = 0 },
            completion: { _ in label.removeFromSuperview() }
        )
    }

    private static func pin(
        _ label: UILabel,
        to view: UIView,
        bottomInset: CGFloat
    ) {
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            label.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -bottomInset
            ),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: 24
            ),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -24
            )
        ])
    }

    private static func makeLabel(_ text: String) -> UILabel {
        let label = PaddedLabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.85)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.layer.cornerRadius = 18
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(
        top: 10, left: 18, bottom: 10, right: 18
    )

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}
