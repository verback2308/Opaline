// swiftlint:disable file_length
import AVFoundation
import UIKit

// MARK: - Vote Formatting

private func formatVoteCount(_ count: Int) -> String {
    switch count {
    case 0 ..< 1_000:
        "\(count)"
    case 1_000 ..< 1_000_000:
        String(
            format: "%.1fK",
            Double(count) / 1_000
        )
    default:
        String(
            format: "%.1fM",
            Double(count) / 1_000_000
        )
    }
}

// MARK: - Initial State

extension WatchViewController {
    func loadInitialState() {
        titleLabel.text = initialVideo.title
        metaLabel.text = buildMetaText(
            viewCount: initialVideo.viewCount,
            publishedAt: initialVideo.publishedAt
        )
        channelNameLabel.text = initialVideo.channelName
        channelMetaLabel.text = nil
        subscribeButton.isHidden =
            !OAuthClient.shared.isAnonymous
        subscribeButton.setTitle("common.subscribe".localized, for: .normal)
        descriptionText = ""
        descriptionLabel.attributedText = nil
        descriptionButton.isHidden = true
        resetComments()
        loadInitialAvatar()
        startPlayback()
    }

    func loadInitialAvatar() {
        if let avatarStr = initialVideo.channelAvatarURL,
           let url = URL(string: avatarStr) {
            channelAvatarView.setImage(url: url)
        } else if let channelId = initialVideo.channelId {
            fetchChannelAvatar(channelId: channelId)
        } else {
            channelAvatarView.cancel()
        }
    }

    func fetchChannelAvatar(channelId: String) {
        channelInfoStore.fetch(
            channelId: channelId
        ) { [weak self] result in
            guard let self,
                  case let .success(info) = result,
                  let avatarStr = info.avatarURL,
                  let url = URL(string: avatarStr)
            else {
                return
            }
            channelAvatarView.setImage(url: url)
        }
    }

    func buildMetaText(
        viewCount: String?,
        publishedAt: String?
    )
        -> String {
        [
            viewCount,
            publishedAt.map(
                VideoFormatters.formatRelativeDate
            )
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " • ")
    }
}

// MARK: - Watch Page

extension WatchViewController {
    func loadWatchPage() {
        client.fetchWatchPage(
            video: initialVideo,
            cancellationToken: pageLoadToken
        ) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case let .success(page):
                    self?.applyWatchPage(page)
                case let .failure(error):
                    AppLog.player(
                        "watch page load failed "
                            + "\(self?.initialVideo.id ?? "nil")"
                            + ": \(error)"
                    )
                }
            }
        }
    }

    func applyWatchPage(_ page: WatchPage) {
        watchPage = page
        cache.setWatchPage(page, videoId: initialVideo.id)
        title = page.video.title
        titleLabel.text = page.video.title
        metaLabel.text = buildMetaText(
            viewCount: page.video.viewCount,
            publishedAt: page.video.publishedAt
        )
        applyChannelInfo(from: page)
        applySubscriptionState(from: page)
        applyEngagementData(from: page)
        applyTheme()
        applyRelatedVideos(from: page)
        updateTransportAvailability()
        startSideEffects(for: page.video.id)
        view.setNeedsLayout()
    }

    /// RYD/SponsorBlock, playlist prefetch and the first comments page —
    /// kicked off once per video. `applyWatchPage` runs twice (cache, then
    /// network); everything above this is UI application and safe to
    /// re-run, but these are one-shot network calls.
    private func startSideEffects(for videoId: String) {
        guard sideEffectsStartedForVideoId != videoId else {
            return
        }
        sideEffectsStartedForVideoId = videoId
        fetchExternalServiceData(videoId: videoId)
        prefetchPlaylistOptions()
        resetComments()
        loadComments()
    }

    func applyChannelInfo(from page: WatchPage) {
        if let channelInfo = page.channelInfo {
            channelNameLabel.text = channelInfo.title.isEmpty
                ? initialVideo.channelName
                : channelInfo.title
            channelMetaLabel.text = channelInfo.subscriberCountText
            if let avatarStr = channelInfo.avatarURL,
               let url = URL(string: avatarStr) {
                channelAvatarView.setImage(url: url)
            } else if let chId = page.video.channelId {
                fetchChannelAvatar(channelId: chId)
            }
            return
        }
        let name = page.video.channelName.isEmpty
            ? initialVideo.channelName
            : page.video.channelName
        channelNameLabel.text = name
        channelMetaLabel.text = nil
        if let chId = page.video.channelId {
            fetchChannelAvatar(channelId: chId)
        } else {
            channelAvatarView.cancel()
        }
    }

    func applySubscriptionState(from page: WatchPage) {
        let buttonText = page.subscribeButtonText
            ?? (page.isSubscribed
                ? "common.subscribed".localized
                : "common.subscribe".localized)
        subscribeButton.setTitle(
            buttonText,
            for: .normal
        )
        isSubscribed = page.isSubscribed
        subscribeButton.isHidden = false
        descriptionText = page.description ?? ""
        applyDescriptionText()
        descriptionExpanded = false
        updateDescriptionUI()
    }

    /// Rebuilds the description's attributed text — called both when the
    /// video's description is applied and when the theme changes, since the
    /// link color is baked into the attributed string. The linkify pass is
    /// skipped when neither input changed since the last call (the watch
    /// page landing twice, or a theme re-apply with the same text).
    func applyDescriptionText() {
        let theme = ThemeManager.shared
        if let cached = descriptionAttributedCache,
           cached.text == descriptionText,
           cached.isDark == theme.isDark {
            descriptionLabel.attributedText = cached.attributed
            descriptionLabel.linkTextAttributes = [.foregroundColor: theme.accent]
            return
        }
        let attributed = LinkifiedText.attributedString(
            from: descriptionText,
            font: UIFont.systemFont(ofSize: 13),
            color: theme.secondaryText,
            includeTimestamps: true
        )
        descriptionAttributedCache = DescriptionAttributedCache(
            text: descriptionText,
            isDark: theme.isDark,
            attributed: attributed
        )
        descriptionLabel.attributedText = attributed
        descriptionLabel.linkTextAttributes = [.foregroundColor: theme.accent]
    }

    func applyEngagementData(from page: WatchPage) {
        // The watch page never carries these — they arrive later from
        // Return YouTube Dislike, and this runs again when the network page
        // lands, so writing a placeholder here wiped the real numbers.
        if let count = page.likeCount {
            likeCountLabel.text = count
        }
        currentLikeStatus =
            page.likeStatus ?? .indifferent
        updateLikeDislikeUI()
    }

    func fetchExternalServiceData(videoId: String) {
        if ReturnYouTubeDislikeService.enabled {
            fetchRYDVotes(videoId: videoId)
        }
        if SponsorBlockService.enabled {
            fetchSponsorSegments(videoId: videoId)
        }
    }

    func fetchRYDVotes(videoId: String) {
        ReturnYouTubeDislikeService.shared.fetchVotes(
            videoId: videoId
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.watchPage?.video.id
                      == videoId
                else {
                    return
                }
                if case let .success(votes) = result {
                    self.likeCountLabel.text =
                        formatVoteCount(votes.likes)
                    self.dislikeCountLabel.text =
                        formatVoteCount(votes.dislikes)
                }
            }
        }
    }

    func fetchSponsorSegments(videoId: String) {
        SponsorBlockService.shared.fetchSegments(
            videoId: videoId
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.watchPage?.video.id
                      == videoId
                else {
                    return
                }
                if case let .success(segments) = result {
                    self.sponsorBlock.segments = segments
                    self.videoPlayerView?
                        .setSponsorSegments(segments)
                }
            }
        }
    }

    func applyRelatedVideos(from page: WatchPage) {
        var related = page.relatedVideos
        // Up next leads the related list, except in a queue: there it is the
        // next queued item and already sits in the section above.
        let queued = Set((page.playlistVideos ?? []).map(\.id))
        if let next = page.nextVideo, !queued.contains(next.id) {
            related.removeAll { $0.id == next.id }
            let enriched = enrichWithChannelId(next, from: related)
            related.insert(enriched, at: 0)
        }
        // The page arrives twice — from the cache, then from the network —
        // and YouTube's pivot differs between the two calls. Replacing the
        // list would reshuffle it while it is being read, so what is already
        // on screen stays put and only genuinely new videos are appended.
        // In memory only: the merged list is this screen's, the cache keeps
        // the response it was given.
        if !allRelatedVideos.isEmpty {
            let known = Set(allRelatedVideos.map(\.id))
            related = allRelatedVideos
                + related.filter { !known.contains($0.id) }
        }
        isLoadingRelated = false
        allRelatedVideos = related
        visibleRelatedVideos = Array(
            related.prefix(WatchPaging.relatedBatch)
        )
        populateQueueIfNeeded(from: page)
        refreshQueuePanel()
        relatedCollectionView.reloadData()
        // Zeroed here and not only on the way out of the previous video: the
        // list is often handed its content while the sidebar has no size yet,
        // and when the frame grows from zero the flow layout answers with a
        // proportional offset — 384 pt into 98 pt of content, i.e. the list
        // opens somewhere in its middle.
        relatedCollectionView.setContentOffset(.zero, animated: false)
    }

    /// Which queue this page belongs to is decided by its playlist, not by
    /// "is this video somewhere in the list": overlapping mixes used to
    /// graft onto each other, and a plain video opened after a mix inherited
    /// everything already played.
    private func populateQueueIfNeeded(
        from page: WatchPage
    ) {
        let playlistId = page.video.playlistId
        if let vids = page.playlistVideos, !vids.isEmpty {
            if playlistId != nil, playlistId == queue.playlistId {
                // The window this page brought reaches further than the one
                // the queue was built from — fold in what is new, or the
                // queue only drains and autoplay stops after 20 (#73).
                queue.append(vids)
            } else {
                queue.setQueue(
                    vids,
                    playlistId: playlistId,
                    title: page.playlistTitle,
                    continuation: page.queueContinuation,
                    shuffleParams: page.shuffleParams
                )
                AppLog.player(
                    "queue opened: \(vids.count) videos,"
                        + " shuffle=\(page.shuffleParams != nil),"
                        + " more=\(page.queueContinuation != nil)"
                )
            }
        } else if queue.playlistId != nil
            || !queue.videos.contains(where: { $0.id == page.video.id }) {
            // Out of the playlist, or a video nobody queued: whatever the
            // queue held is over. A hand-built queue (no playlist) survives,
            // since walking it is exactly how it is meant to be played.
            queue.clear()
        }
        queue.seekTo(videoId: page.video.id)
    }

    private func enrichWithChannelId(
        _ video: Video,
        from pool: [Video]
    )
        -> Video {
        guard video.channelId == nil
        else { return video }
        let match = pool.first {
            $0.channelId != nil
                && $0.channelName == video.channelName
        }
        guard let chId = match?.channelId
        else { return video }
        // A copy, not a rebuild: everything the renderer came with — shorts
        // flag, playlist id, feedback actions — has to survive the fill-in.
        var enriched = video
        enriched.channelId = chId
        return enriched
    }
}

// MARK: - Load Video

extension WatchViewController {
    /// Fresh open from grid/search/external — clears history.
    func loadVideo(_ video: Video) {
        videoHistory.removeAll()
        loadVideoInternal(video)
        updateLeftBarButton()
    }

    /// Navigate within player (related, autoplay) — pushes current to history.
    func navigateTo(_ video: Video) {
        let current = watchPage?.video ?? initialVideo
        videoHistory.append(current)
        loadVideoInternal(video, keepFullscreen: isPlayerFullscreen)
        updateLeftBarButton()
        updateTransportAvailability()
    }

    /// Go back to previous video in history stack.
    func goBack() {
        guard let previous = videoHistory.popLast()
        else { return }
        loadVideoInternal(previous)
        updateLeftBarButton()
        updateTransportAvailability()
    }

    private func loadVideoInternal(
        _ video: Video,
        keepFullscreen: Bool = false
    ) {
        dismissAutoplayOverlay()
        applyResumePolicy(for: video)
        pageLoadToken.cancel()
        pageLoadToken = CancellationToken()
        let isBg = UIApplication.shared.applicationState != .active
        if isBg {
            savedPlayerForBackground = videoPlayerView?.player
        } else {
            resetPlaybackSurfaces()
        }
        playbackFacade.reset()
        resetVideoState()
        scrollView.setContentOffset(.zero, animated: false)
        if !keepFullscreen {
            exitFullscreenIfNeeded()
        }
        initialVideo = video
        loadInitialState()
        loadWatchPage()
        applyTheme()
    }

    func resetVideoState() {
        recoveryStartedAt = nil
        // Loop is a property of the video you turned it on for.
        videoPlayerView?.isLooping = false
        watchPage = nil
        isLoadingRelated = true
        allRelatedVideos = []
        visibleRelatedVideos = []
        sideEffectsStartedForVideoId = nil
        relatedCollectionView.reloadData()
        // The screen is reused for the next video, and in landscape the
        // sidebar scrolls on its own — without this the new list opens at
        // wherever the last one was left, headers already off the top.
        relatedCollectionView.setContentOffset(.zero, animated: false)
        commentThreads = []
        commentRows = []
        commentHeightCache = [:]
        commentsContinuation = nil
        isLoadingComments = false
        descriptionExpanded = false
        likeCountLabel.text = "—"
        dislikeCountLabel.text = "—"
        currentLikeStatus = .indifferent
        sponsorBlock.reset()
        // Returns to the collapsed preview and drops the previous video's
        // rows before `resetComments()`/`loadInitialState()` render the new
        // one, so nothing from the old video is ever visible mid-switch.
        collapseComments()
        commentsStackView.arrangedSubviews
            .forEach { $0.removeFromSuperview() }
        commentsTableView.reloadData()
    }

    /// Seeks the active player to an absolute position, used by tapped
    /// timestamps in the description and in comments.
    func seekPlayer(toSeconds seconds: Int) {
        videoPlayerView?.player?.seek(
            to: CMTime(seconds: Double(seconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

// MARK: - Linkified Text Taps

extension WatchViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        LinkifiedText.handleTap(url: URL) { [weak self] seconds in
            self?.seekPlayer(toSeconds: seconds)
        }
    }
}
