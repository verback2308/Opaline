import AVFoundation
import UIKit

/// Holds a player at the boosted rate for as long as a press lasts, and
/// keeps the "2x" pill honest. Watching `rate` is what makes it hold: a loop
/// restarting the item, the end screen's replay or a remote Play all go
/// through `play()`, which drops back to 1x under a finger still asking for
/// 2x — those are put back. A stop (end of item, remote Pause, a call) hides
/// the pill instead, and stays a stop when the finger lifts.
final class SpeedBoostHold {
    let badge = SpeedBoostBadge()
    private(set) var isActive = false
    private var rate: Float = SpeedBoostBadge.boostedRate
    private var observation: NSKeyValueObservation?

    /// Starts the boost on a playing player; a paused one is left alone.
    func begin(_ player: AVPlayer, rate: Float) -> Bool {
        guard player.rate > 0 else {
            return false
        }
        isActive = true
        self.rate = rate
        player.rate = rate
        badge.setVisible(true)
        observation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async { self?.follow(player) }
        }
        return true
    }

    /// Ends the boost, back to `normal` unless playback stopped meanwhile.
    func end(_ player: AVPlayer?, restoring normal: Float) {
        guard isActive else {
            return
        }
        isActive = false
        observation = nil
        badge.setVisible(false)
        if let player, player.rate > 0 {
            player.rate = normal
        }
    }

    private func follow(_ player: AVPlayer) {
        guard isActive else {
            return
        }
        guard player.rate > 0 else {
            badge.setVisible(false)
            return
        }
        if player.rate != rate {
            player.rate = rate
        }
        badge.setVisible(true)
    }
}
