import UIKit

/// Press and hold a short to watch it at 2x while the finger stays down,
/// as in the official app (#149). The press goes on the feed itself: the
/// overlay lets touches on bare picture through, and a long press cancels
/// the tap that would otherwise pause the short. A finger that moves is a
/// swipe to the next short, which fails the press before it begins.
final class ShortsSpeedBoost: NSObject, UIGestureRecognizerDelegate {
    private let badge = SpeedBoostBadge()
    private weak var player: ShortsPlayerView?
    private var isBoosting = false

    func attach(
        to feed: UIView,
        badgeHost: UIView,
        player: ShortsPlayerView
    ) {
        self.player = player
        badge.install(in: badgeHost)
        let press = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handlePress(_:))
        )
        press.minimumPressDuration = 0.35
        press.delegate = self
        feed.addGestureRecognizer(press)
    }

    @objc
    private func handlePress(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            guard player?.startSpeedBoost() == true else {
                return
            }
            isBoosting = true
            badge.superview?.bringSubviewToFront(badge)
            badge.setVisible(true)
        case .ended, .cancelled, .failed:
            guard isBoosting else {
                return
            }
            isBoosting = false
            badge.setVisible(false)
            player?.stopSpeedBoost()
        default:
            break
        }
    }

    /// The action rail's buttons keep their own presses.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var current = touch.view
        while let candidate = current {
            if candidate is UIControl {
                return false
            }
            current = candidate.superview
        }
        return true
    }
}
