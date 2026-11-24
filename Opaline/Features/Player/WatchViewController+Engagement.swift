import UIKit

// MARK: - Engagement & Actions

extension WatchViewController {
    // MARK: - App Lifecycle

    @objc
    func appDidEnterBackground() {
        let bgEnabled = BackgroundPlaybackService.isEnabled
        AppLog.player(
            "appDidEnterBackground: bgEnabled=\(bgEnabled)"
        )
        backgroundEnteredAt = Date()
        // Layer/PiP background handling lives in VideoPlayerView.
        guard !bgEnabled else {
            return
        }
        // Auto-PiP may still be starting — pausing now would kill it, so the
        // decision waits a tick for the controller's real state.
        DispatchQueue.main.async { [weak self] in
            guard self?.videoPlayerView?.isPiPActive != true else {
                return
            }
            self?.videoPlayerView?.player?.pause()
        }
    }

    @objc
    func appWillEnterForeground() {
        AppLog.player("appWillEnterForeground")
        let elapsed = backgroundEnteredAt.map {
            Date().timeIntervalSince($0)
        } ?? 0
        backgroundEnteredAt = nil
        // A failed item never plays again by itself, and a recovery begun
        // during a background wake-up can stall with the app suspended under
        // it: either left a black screen and a spinner. A recovery under a
        // minute old is still resolving and left to finish.
        let failed = videoPlayerView?.player?.currentItem?.status == .failed
        let fresh = recoveryStartedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
        let resolving = isRecoveringPlayback && fresh
        if !resolving, failed || isRecoveringPlayback {
            isRecoveringPlayback = false
            AppLog.player("foreground: playback failed or stalled in the background, recovering")
            recoverPlayback()
            return
        }
        if elapsed > 120, hasSeenPlaybackError {
            AppLog.player(
                "foreground: URLs likely expired"
                    + " (\(Int(elapsed))s in bg), recovering"
            )
            recoverPlayback()
        }
    }

    // MARK: - Theming

    private func applyThemeToText(_ theme: ThemeManager) {
        for label in [titleLabel, channelNameLabel, commentsLabel] {
            label.textColor = theme.primaryText
        }
        for label in [metaLabel, channelMetaLabel, likeCountLabel, dislikeCountLabel] {
            label.textColor = theme.secondaryText
        }
        descriptionButton.setTitleColor(theme.secondaryText, for: .normal)
        applyDescriptionText()
    }

    /// Reaches every surface that can show a comment, including the panel
    /// (open or not — it may be off-screen but attached, or entirely
    /// detached) and the table's cells. Cells read `ThemeManager.shared` at
    /// `configure(_:linkDelegate:)` time (see `CommentContentView`), so a
    /// `reloadData()` here is enough to repaint both the currently visible
    /// rows and any already-dequeued ones the next time they're reused.
    private func applyThemeToComments(_ theme: ThemeManager) {
        // The fill lives on `commentsPreviewCard`, not on the stack view —
        // a stack view ignores `backgroundColor` before iOS 14.
        commentsPreviewCard.backgroundColor = theme.surface
        // `surface` sits close to `background` in both themes, so the card
        // needs an outline of its own to read as a separate block.
        commentsPreviewCard.layer.borderWidth = 1
        commentsPreviewCard.layer.borderColor = theme.separator.cgColor
        commentPreviewContentView.applyTheme()
        commentsPanel.applyTheme(theme)
        loadedQueuePanel?.applyTheme(theme)
        commentsTableView.reloadData()
    }

    @objc
    func applyTheme() {
        let theme = ThemeManager.shared
        view.backgroundColor = theme.background
        scrollView.backgroundColor = theme.background
        contentView.backgroundColor = theme.background
        relatedCollectionView.backgroundColor = theme.background
        sidebarContainer.backgroundColor = theme.background
        applyThemeToText(theme)
        applyThemeToComments(theme)
        for btn in [likeButton, dislikeButton, shareButton, saveButton, downloadButton] {
            btn.tintColor = theme.primaryText
        }
        playerContainer.backgroundColor = .black
        playerStatusLabel.textColor = .lightGray
        applyThemeToSubscribeButton()
        if isViewLoaded, navigationController != nil {
            setupNavigationBar()
        }
        updateLikeDislikeUI()
        // The loop above resets every action tint, including the accent that
        // marks an already-saved video.
        updateSaveButton()
        updateDownloadButton()
    }

    func applyThemeToSubscribeButton() {
        let theme = ThemeManager.shared
        // State-driven, not title-driven: the title is localized (and may
        // even be server-provided text).
        if isSubscribed {
            subscribeButton.backgroundColor = theme.surface
            subscribeButton.setTitleColor(theme.primaryText, for: .normal)
        } else {
            subscribeButton.backgroundColor = theme.accent
            subscribeButton.setTitleColor(.white, for: .normal)
        }
    }

    // MARK: - Description

    func updateDescriptionUI() {
        let hasDesc = !descriptionText.isEmpty
        descriptionLabel.isHidden = !descriptionExpanded
        channelTopToMeta?.isActive = !descriptionExpanded
        channelTopToDesc?.isActive = descriptionExpanded
        descriptionButton.isHidden = !hasDesc
        descriptionButton.setTitle(
            descriptionExpanded
                ? "player.description.less".localized
                : "player.description.more".localized,
            for: .normal
        )
        view.setNeedsLayout()
    }

    @objc
    func toggleDescription() {
        descriptionExpanded.toggle()
        updateDescriptionUI()
    }

    // MARK: - Like / Dislike

    func updateLikeDislikeUI() {
        let tint = ThemeManager.shared.primaryText
        let activeTint = ThemeManager.shared.accent
        let secondary = ThemeManager.shared.secondaryText
        likeButton.tintColor = currentLikeStatus == .like
            ? activeTint : tint
        likeCountLabel.textColor = currentLikeStatus == .like
            ? activeTint : secondary
        dislikeButton.tintColor = currentLikeStatus == .dislike
            ? activeTint : tint
        dislikeCountLabel.textColor = currentLikeStatus == .dislike
            ? activeTint : secondary
    }

    func handleLikeToggleResult(
        _ result: Result<Void, Error>,
        videoId: String,
        wasLiked: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            let label = wasLiked
                ? "removeLike" : "sendLike"
            switch result {
            case .success:
                AppLog.player("\(label) success for \(videoId)")
                let rydVal = wasLiked ? 0 : 1
                if ReturnYouTubeDislikeService.enabled {
                    ReturnYouTubeDislikeService.shared
                        .reportVote(
                            videoId: videoId,
                            value: rydVal
                        )
                }
            case let .failure(error):
                AppLog.player(
                    "\(label) failed for \(videoId): \(error)"
                )
                let revert: LikeStatus = wasLiked
                    ? .like : .indifferent
                self?.currentLikeStatus = revert
                self?.updateLikeDislikeUI()
            }
        }
    }

    func handleDislikeToggleResult(
        _ result: Result<Void, Error>,
        videoId: String,
        wasDisliked: Bool
    ) {
        DispatchQueue.main.async {
            let label = wasDisliked
                ? "removeDislike" : "sendDislike"
            switch result {
            case .success:
                AppLog.player("\(label) success for \(videoId)")
                let rydVal = wasDisliked ? 0 : -1
                if ReturnYouTubeDislikeService.enabled {
                    ReturnYouTubeDislikeService.shared
                        .reportVote(
                            videoId: videoId,
                            value: rydVal
                        )
                }
            case let .failure(error):
                AppLog.player(
                    "\(label) failed for \(videoId): \(error)"
                )
            }
        }
    }
}
