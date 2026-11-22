import AVFoundation
import notify

/// Pauses playback the moment the screen locks when background playback is
/// off.
///
/// UIKit has no lock event. `didEnterBackground` does arrive at once, but
/// on lock the main thread is then held for about three seconds (measured on
/// an A9X iPad, iOS 14 — with or without PiP), so a pause dispatched from
/// there lands late and the audio, which AVPlayer renders out of process,
/// plays on meanwhile. SpringBoard's lock notification is a Darwin one: it
/// reaches a background queue ~0.1 s after the lock, while the main thread
/// is still held.
///
/// The player view arms this as the app goes to the background, on the
/// main thread; the player to pause is tracked from every assignment, so
/// nothing here reads view state from another queue.
final class ScreenLockPause {
    static let shared = ScreenLockPause()

    private let lock = NSLock()
    /// The most recently attached player. Tracked apart from arming so a
    /// player attached while backgrounded (autoplay, recovery, PiP rebuild)
    /// is still the one paused.
    private weak var current: AVPlayer?
    private var isArmed = false
    /// The player this last paused, until its rate change is seen on main.
    private weak var paused: AVPlayer?
    private var token = NOTIFY_TOKEN_INVALID

    private init() {
        notify_register_dispatch(
            "com.apple.springboard.lockcomplete",
            &token,
            DispatchQueue.global(qos: .userInteractive)
        ) { [weak self] _ in
            self?.screenLocked()
        }
    }

    /// Whether to pause on the next screen lock.
    func arm(_ armed: Bool) {
        lock.lock()
        isArmed = armed
        if armed {
            paused = nil
        }
        lock.unlock()
    }

    /// Called on every player view `player` change. A detach (nil) only
    /// clears the player it detaches, so an old view letting go after a new
    /// one attached does not drop the new player.
    func track(_ old: AVPlayer?, _ new: AVPlayer?) {
        lock.lock()
        if new != nil || current === old {
            current = new
        }
        lock.unlock()
    }

    private func screenLocked() {
        lock.lock()
        let player = isArmed ? current : nil
        isArmed = false
        guard let player, player.rate > 0 else {
            lock.unlock()
            return
        }
        paused = player
        lock.unlock()
        AppLog.player("screen locked with background playback off, pausing")
        player.pause()
    }

    /// True once for the pause this made, so the rate observer does not take
    /// it for a multitasking pause: the main thread is held on lock, and a
    /// quick unlock can make the app active before the rate change lands.
    func takePause(of player: AVPlayer?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let player, paused === player else {
            return false
        }
        paused = nil
        return true
    }
}
