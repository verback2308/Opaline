import UIKit

// MARK: - Auth Flow
extension AuthViewController {
    func startAuth() {
        OAuthClient.shared.requestDeviceCode { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self?.handleAuthFailure(error)
                case .success(let code):
                    self?.handleDeviceCode(code)
                }
            }
        }
    }

    func handleDeviceCode(_ code: OAuthClient.DeviceCodeResponse) {
        codeLabel.text = code.userCode
        verificationURL = URL(string: code.verificationURL)
        showCodeControls(true)
        openButton.setTitle("auth.openDevicePage".localized, for: .normal)
        statusLabel.text = "auth.waiting".localized

        let config = OAuthClient.PollConfig(
            deviceCode: code.deviceCode,
            clientId: code.clientId,
            clientSecret: code.clientSecret,
            interval: code.interval
        )
        OAuthClient.shared.pollForToken(
            config: config
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    OAuthClient.shared.isAnonymous = false
                    UserProfileStore.shared.load()
                    self?.onAuthorized?()
                case .failure(let error):
                    self?.handleAuthFailure(error)
                }
            }
        }
    }

    /// A device code is one-shot and short-lived: once polling ends in an
    /// error (usually `expired_token`) the only cure is a brand new code,
    /// so fetch one instead of stranding the user on a dead screen.
    /// ponytail: three attempts per screen, no backoff — a permanent
    /// failure (no network, bad credentials) would otherwise loop forever.
    func handleAuthFailure(_ error: Error) {
        AppLog.auth("auth failed: \(error)")
        // Retrying a dead network just burns another 60s URLSession
        // timeout; only an expired/denied code deserves a fresh one.
        let isOffline = (error as NSError).domain == NSURLErrorDomain
        guard !isOffline, retryCount < 3 else {
            statusLabel.text = isOffline
                ? "auth.offline".localized
                : "auth.failed".localized
            // No code left, so the same button now restarts the flow —
            // `openVerificationURL` falls back to `restartAuth`.
            openButton.setTitle("auth.tryAgain".localized, for: .normal)
            openButton.isHidden = false
            spinner.stopAnimating()
            return
        }
        retryCount += 1
        requestNewCode()
    }

    @objc
    func restartAuth() {
        retryCount = 0
        requestNewCode()
    }

    func requestNewCode() {
        codeLabel.text = nil
        verificationURL = nil
        showCodeControls(false)
        statusLabel.text = "auth.fetchingCode".localized
        spinner.startAnimating()
        startAuth()
    }

    /// The code, its copy button and the "paste it there" instruction only
    /// make sense together — hide them as one while there is no code.
    func showCodeControls(_ visible: Bool) {
        copyButton.isHidden = !visible
        instructionLabel.isHidden = !visible
        openButton.isHidden = !visible
    }
}
