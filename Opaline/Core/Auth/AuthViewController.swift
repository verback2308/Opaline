import UIKit
import SafariServices

final class AuthViewController: UIViewController {
    var onAuthorized: (() -> Void)?
    var onContinueAnonymously: (() -> Void)?

    private let titleLabel = UILabel()
    let instructionLabel = UILabel()
    let codeLabel = UILabel()
    let statusLabel = UILabel()
    let openButton = UIButton(type: .system)
    let copyButton = UIButton(type: .system)
    private let anonymousButton = UIButton(type: .system)
    let spinner = UIActivityIndicatorView(style: .white)
    private let contentStack = UIStackView()

    var verificationURL: URL?
    var retryCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        startAuth()
    }

    private func setupUI() {
        configureLabels()
        configureButtons()
        configureSpinner()
        addControlSubviews()
        configureStack()
        layoutTitleAndCode()
        layoutButtonsAndStatus()
    }

    @objc
    private func openVerificationURL() {
        guard let url = verificationURL else {
            restartAuth()
            return
        }
        UIPasteboard.general.string = codeLabel.text
        let safari = SFSafariViewController(url: localized(url))
        present(safari, animated: true)
    }

    /// Google picks the page language from the IP, not from
    /// `Accept-Language` — a Japanese user on a foreign network lands on a
    /// page they cannot read. `hl` overrides that with the app's language.
    private func localized(_ url: URL) -> URL {
        guard let code = AppLanguage.override?.rawValue
            ?? Locale.preferredLanguages.first,
            var components = URLComponents(
                url: url, resolvingAgainstBaseURL: false
            ) else {
            return url
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "hl", value: code))
        components.queryItems = items
        return components.url ?? url
    }

    @objc
    private func continueAnonymously() {
        OAuthClient.shared.isAnonymous = true
        if let cb = onContinueAnonymously {
            cb()
        } else {
            onAuthorized?()
        }
    }
}

// MARK: - Configuration
private extension AuthViewController {
    func configureLabels() {
        titleLabel.text = "auth.title".localized
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 22)
        titleLabel.textAlignment = .center

        instructionLabel.text = "auth.instruction".localized
        instructionLabel.textColor = .lightGray
        instructionLabel.font = UIFont.systemFont(ofSize: 15)
        instructionLabel.textAlignment = .center
        instructionLabel.numberOfLines = 0
        instructionLabel.isHidden = true

        codeLabel.textColor = .white
        codeLabel.font = UIFont(
            name: "Menlo-Bold",
            size: 36
        ) ?? UIFont.boldSystemFont(ofSize: 36)
        codeLabel.textAlignment = .center

        statusLabel.text = "auth.fetchingCode".localized
        statusLabel.textColor = .lightGray
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
    }

    func configureButtons() {
        configureCopyButton()
        configureOpenButton()
        configureAnonymousButton()
    }

    func configureOpenButton() {
        openButton.setTitle(
            "auth.openDevicePage".localized,
            for: .normal
        )
        openButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        openButton.backgroundColor = ThemeManager.shared.accent
        openButton.setTitleColor(.white, for: .normal)
        openButton.layer.cornerRadius = 10
        openButton.contentEdgeInsets = UIEdgeInsets(
            top: 14, left: 28, bottom: 14, right: 28
        )
        openButton.addTarget(
            self,
            action: #selector(openVerificationURL),
            for: .touchUpInside
        )
        openButton.isHidden = true
    }

    func configureAnonymousButton() {
        anonymousButton.setTitle(
            "auth.continueAnonymously".localized,
            for: .normal
        )
        anonymousButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        anonymousButton.setTitleColor(
            UIColor(white: 0.55, alpha: 1),
            for: .normal
        )
        anonymousButton.addTarget(
            self,
            action: #selector(continueAnonymously),
            for: .touchUpInside
        )
    }

    func configureSpinner() {
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
    }

    /// A stack, not constraints: hiding the code, its copy button or the
    /// instruction has to close the gap they leave behind.
    func configureStack() {
        contentStack.axis = .vertical
        contentStack.alignment = .center
        contentStack.spacing = 16
        let arranged: [UIView] = [
            codeLabel, copyButton, instructionLabel,
            openButton, statusLabel, spinner
        ]
        arranged.forEach(contentStack.addArrangedSubview)
        contentStack.setCustomSpacing(8, after: codeLabel)
        contentStack.setCustomSpacing(28, after: instructionLabel)
        contentStack.setCustomSpacing(28, after: openButton)
    }

    func addControlSubviews() {
        let views: [UIView] = [titleLabel, contentStack, anonymousButton]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
    }
}

// MARK: - Layout
private extension AuthViewController {
    func layoutTitleAndCode() {
        layoutTitleConstraints(padding: 40)
    }

    func layoutTitleConstraints(padding: CGFloat) {
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            titleLabel.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 80
            ),
            titleLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: padding
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -padding
            )
        ])
    }

    func layoutButtonsAndStatus() {
        let padding: CGFloat = 40
        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            contentStack.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: 48
            ),
            contentStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: padding
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -padding
            ),
            instructionLabel.widthAnchor.constraint(
                equalTo: contentStack.widthAnchor
            ),
            anonymousButton.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            anonymousButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -28
            )
        ])
    }
}
