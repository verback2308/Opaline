import UIKit

/// Holds transcoding while the app is in the background. iOS takes the
/// hardware encoder away there, so frames encoded then are lost, and a chunk
/// that fails makes the player drop what it had buffered. Waiting instead
/// leaves the request open; it is answered once the app is back.
final class AV1ForegroundGate {
    static let shared = AV1ForegroundGate()

    private let condition = NSCondition()
    private var inBackground = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.set(background: true)
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.set(background: false)
            }
        ]
    }

    /// Blocks the calling (transcode) thread while the app is in the
    /// background, unless the work is cancelled meanwhile.
    func waitForForeground(unless cancel: CancelFlag) {
        condition.lock()
        while inBackground, !cancel.isRaised {
            condition.wait(until: Date(timeIntervalSinceNow: 0.5))
        }
        condition.unlock()
    }

    private func set(background: Bool) {
        condition.lock()
        inBackground = background
        condition.broadcast()
        condition.unlock()
    }
}
