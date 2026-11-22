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
