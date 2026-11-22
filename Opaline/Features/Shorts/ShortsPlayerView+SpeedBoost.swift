import UIKit

// MARK: - Hold for 2x

extension ShortsPlayerView {
    /// Holds a playing short at 2x; returns false for a paused one, which a
    /// press must not start.
    func startSpeedBoost() -> Bool {
        guard player.rate > 0 else {
            return false
        }
        player.rate = SpeedBoostBadge.boostedRate
        return true
    }

    /// Back to normal speed, unless playback stopped during the hold.
    func stopSpeedBoost() {
        if player.rate > 0 {
            player.rate = 1
        }
    }
}
