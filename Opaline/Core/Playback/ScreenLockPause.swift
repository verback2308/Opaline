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
/// The player view arms this with its player as the app goes to the
/// background, on the main thread, so nothing here reads view state from
/// another queue.
final class ScreenLockPause {
    static let shared = ScreenLockPause()

    private let lock = NSLock()
    private weak var armed: AVPlayer?
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

    /// The player to pause if the screen locks before the app is active
    /// again; nil disarms.
    func arm(_ player: AVPlayer?) {
        lock.lock()
        armed = player
        lock.unlock()
    }

    private func screenLocked() {
        lock.lock()
        let player = armed
        armed = nil
        lock.unlock()
        guard let player, player.rate > 0 else {
            return
        }
        AppLog.player("screen locked with background playback off, pausing")
        player.pause()
    }

    deinit {
        notify_cancel(token)
    }
}
