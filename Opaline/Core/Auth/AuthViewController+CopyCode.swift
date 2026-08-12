import UIKit

// MARK: - Copy code
extension AuthViewController {
    func configureCopyButton() {
        copyButton.setTitle("auth.copyCode".localized, for: .normal)
        copyButton.titleLabel?.font = UIFont.systemFont(
            ofSize: 15, weight: .medium
        )
        copyButton.setTitleColor(ThemeManager.shared.accent, for: .normal)
        copyButton.contentEdgeInsets = UIEdgeInsets(
            top: 8, left: 16, bottom: 8, right: 16
        )
        copyButton.addTarget(
            self,
            action: #selector(copyDeviceCode),
            for: .touchUpInside
        )
        copyButton.isHidden = true
    }

    @objc
    func copyDeviceCode() {
        guard let code = codeLabel.text, !code.isEmpty else {
            return
        }
        UIPasteboard.general.string = code
        // Clears the "Continue Anonymously" button pinned to the bottom.
        ToastView.show(
            "auth.codeCopied".localized,
            in: view,
            bottomInset: 90
        )
    }
}
