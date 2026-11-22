import UIKit

// MARK: - Fullscreen Swipes

/// Swipe up on the inline player enters fullscreen and swipe down leaves it,
/// as in the official app. Both go through the fullscreen button's delegate
/// call, so iPhone still rotates and iPad still fills the window.
extension VideoPlayerView {
    func addFullscreenSwipeGestures() {
        let swipeDown = UISwipeGestureRecognizer(
            target: self,
            action: #selector(handleSwipeDown)
        )
        swipeDown.direction = .down
        swipeDown.delegate = self
        addGestureRecognizer(swipeDown)

        let swipeUp = UISwipeGestureRecognizer(
            target: self,
            action: #selector(handleSwipeUp)
        )
        swipeUp.direction = .up
        swipeUp.delegate = self
        addGestureRecognizer(swipeUp)
    }

    /// Only the swipe that applies may begin: up while inline, down while in
    /// fullscreen. The other one would still recognize, and swallow a touch
    /// that started on a button or was meant for the panel's own drag.
    func allowsFullscreenSwipe(_ swipe: UISwipeGestureRecognizer) -> Bool {
        swipe.direction == .up ? !isFullscreen : isFullscreen
    }

    @objc
    func handleSwipeDown() {
        guard isFullscreen else {
            return
        }
        delegate?.videoPlayerViewDidTapFullscreen(self)
    }

    @objc
    func handleSwipeUp() {
        guard !isFullscreen else {
            return
        }
        delegate?.videoPlayerViewDidTapFullscreen(self)
    }
}

// MARK: - Seek Bar Pan

extension VideoSeekBar {
    /// The bar's drag starts only on sideways movement, as a slider's does: a
    /// flick up that happens to begin on the bar is the fullscreen swipe, not
    /// a seek to wherever the finger lifted.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan.view === self else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) >= abs(velocity.y)
    }
}
