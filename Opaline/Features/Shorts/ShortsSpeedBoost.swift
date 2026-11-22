import UIKit

/// Press and hold a short to watch it at 2x while the finger stays down,
/// as in the official app (#149). The press goes on the feed itself: the
/// overlay lets touches on bare picture through (its action rail sits above
/// the feed, so the rail's buttons never reach this press), and a long press
/// cancels the tap that would otherwise pause the short. A finger that
/// moves is a swipe to the next short, which fails the press before it
/// begins; so does a paused short, whose slow tap should still resume it.
final class ShortsSpeedBoost: NSObject, UIGestureRecognizerDelegate {
    private let hold = SpeedBoostHold()
    private weak var player: ShortsPlayerView?

    func attach(
        to feed: UIView,
        badgeHost: UIView,
        player: ShortsPlayerView
    ) {
        self.player = player
        hold.badge.install(in: badgeHost)
        let press = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handlePress(_:))
        )
        press.minimumPressDuration = 0.35
        press.delegate = self
        feed.addGestureRecognizer(press)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        player?.isPaused == false
    }

    @objc
    private func handlePress(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            guard let player = player?.player else {
                return
            }
            hold.badge.superview?.bringSubviewToFront(hold.badge)
            _ = hold.begin(player, rate: SpeedBoostBadge.boostedRate)
        case .ended, .cancelled, .failed:
            // Shorts have no speed setting of their own.
            hold.end(player?.player, restoring: 1)
        default:
            break
        }
    }
}
