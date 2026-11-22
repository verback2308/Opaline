import UIKit

// MARK: - Playing queue

extension WatchViewController {
    /// Built on first use — a watch screen with no queue never pays for it —
    /// and kept, so a theme change reaches it while it is off screen.
    var queuePanel: QueuePanelController {
        if let loadedQueuePanel {
            return loadedQueuePanel
        }
        let panel = makeQueuePanel()
        loadedQueuePanel = panel
        return panel
    }

    /// A video opened as part of a queue starts from the beginning: resuming
    /// is for coming back to something half-watched, and inside a mix it
    /// drops the listener near the end of a track they never chose to return
    /// to. Set before playback is asked for — the source builds the stream at
    /// the saved playhead itself, and by the time the player has an item it
    /// is already too late.
    func applyResumePolicy(for video: Video) {
        WatchProgressStore.shared.suppressResume = video.playlistId != nil
    }

    /// The queue changed under us — "Play next" adds to it from a menu that
    /// knows nothing about this screen.
    @objc
    func queueDidChange() {
        updateQueueBar()
        if presentedSheet == .queue {
            queuePanel.reload()
        }
    }

    /// The queue as a panel over the player — the same list the related feed
    /// used to carry as a section of its own, where it read as one feed with
    /// the suggestions below it.
    func showQueue() {
        queuePanel.applyTheme(ThemeManager.shared)
        queuePanel.setRepeating(videoPlayerView?.isLooping == true)
        queuePanel.reload()
        presentSheet(.queue, content: queuePanel.sheet)
        queuePanel.scrollToCurrent()
        updateQueueBar()
    }

    /// Shows the strip whenever a queue is playing and there is room for it:
    /// not over a fullscreen player, and not under the panel that lists the
    /// same queue.
    func updateQueueBar() {
        let hasQueue = !queue.videos.isEmpty
        // Repeat belongs to the queue, and the panel owns it there — two
        // repeat controls with different meanings is one too many.
        videoPlayerView?.loopButton.isHidden = hasQueue
        queueBar.isHidden = !hasQueue
            || isPlayerFullscreen
            || presentedSheet != nil
        guard hasQueue, let current = queue.currentVideo else {
            scrollView.contentInset.bottom = 0
            return
        }
        queueBar.configure(
            // A queue with no title is one built by hand with "Play next".
            queueTitle: queue.playlistTitle
                ?? "player.menu.queue".localized,
            current: current.title,
            next: queue.nextVideo?.title
        )
        // The strip floats over a list, so that list needs room to scroll
        // clear of it — the related sidebar in landscape, the page itself in
        // portrait.
        let clearance = queueBar.isHidden ? 0 : QueueBarView.height + 16
        scrollView.contentInset.bottom = queueBarSlot.isLandscape ? 0 : clearance
        relatedCollectionView.contentInset.bottom =
            queueBarSlot.isLandscape ? clearance : 0
    }

    /// Keeps an open panel in step with the queue, which on a mix moves on
    /// with every video.
    func refreshQueuePanel() {
        updateQueueBar()
        guard presentedSheet == .queue else {
            return
        }
        queuePanel.setRepeating(videoPlayerView?.isLooping == true)
        queuePanel.reload()
        queuePanel.scrollToCurrent()
    }

    func makeQueuePanel() -> QueuePanelController {
        let panel = QueuePanelController(queue: queue)
        makeSheetDraggable(panel.sheet)
        panel.applyTheme(ThemeManager.shared)
        panel.onSelect = { [weak self] video in
            self?.requestAutoFullscreenIfEnabled(for: video)
            self?.navigateTo(video)
        }
        panel.onShuffle = { [weak self] in
            self?.shuffleQueue()
        }
        panel.onToggleRepeat = { [weak self] in
            guard let player = self?.videoPlayerView else {
                return
            }
            player.isLooping.toggle()
            self?.queuePanel.setRepeating(player.isLooping)
        }
        panel.onLoadMore = { [weak self] in
            self?.loadMoreQueue()
        }
        panel.onMenu = { [weak self] video, anchor in
            self?.presentQueueItemMenu(for: video, anchor: anchor)
        }
        return panel
    }

    /// The queue's own row menu. What is playing keeps its place in the
    /// list — removing it would be a skip wearing a delete button's clothes.
    private func presentQueueItemMenu(for video: Video, anchor: UIView) {
        VideoActionMenu.present(
            video: video,
            from: self,
            anchor: anchor,
            queue: VideoActionMenu.QueueContext(
                isPlaying: video.id == queue.currentVideo?.id
            ) { [weak self] in
                self?.queue.remove(videoId: video.id)
            }
        )
    }

    /// A toggle: on shuffles, off puts the queue's own order back, on again
    /// draws a new one. Shuffling is the server's where the shelf offers it —
    /// that reaches the whole playlist, not just the part loaded — and ours
    /// over what is loaded where it does not, as on a mix. Either way what is
    /// playing keeps playing; only the order after it changes.
    private func shuffleQueue() {
        guard !queue.isShuffled else {
            queue.unshuffle()
            refreshQueuePanel()
            return
        }
        guard let params = queue.shuffleParams,
              let current = watchPage?.video ?? queue.currentVideo
        else {
            queue.shuffleRemaining()
            refreshQueuePanel()
            return
        }
        client.fetchShuffledQueue(
            video: current,
            params: params
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.applyShuffled(result, current: current)
            }
        }
    }

    private func applyShuffled(
        _ result: Result<WatchPage, Error>,
        current: Video
    ) {
        guard case let .success(page) = result,
              let videos = page.playlistVideos, !videos.isEmpty
        else {
            AppLog.player("queue shuffle failed")
            return
        }
        queue.applyShuffledOrder(
            videos,
            continuation: page.queueContinuation
        )
        refreshQueuePanel()
    }

    private func loadMoreQueue() {
        guard let token = queue.continuation,
              !isLoadingQueuePage
        else {
            return
        }
        isLoadingQueuePage = true
        client.fetchQueuePage(
            continuation: token
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.applyQueuePage(result)
            }
        }
    }

    private func applyQueuePage(
        _ result: Result<FeedPage, Error>
    ) {
        isLoadingQueuePage = false
        guard case let .success(page) = result else {
            AppLog.player("queue paging failed: \(result)")
            return
        }
        queue.appendPage(page)
        AppLog.player(
            "queue paging: +\(page.videos.count),"
                + " total \(queue.videos.count),"
                + " more=\(page.continuation != nil)"
        )
        if presentedSheet == .queue {
            queuePanel.reload()
        }
    }
}
