import UIKit

// MARK: - New-content dots (issue #13)
//
// Dot = the channel's public RSS feed has a video published within the
// resolver's window that isn't in the (server-synced) watch history.
// Watching any recent video of the channel — on any device — clears it.
// RSS is used instead of the subscriptions feed because the TVHTML5
// feed went relevance-first and silently omits some fresh uploads.

extension SubscriptionsViewController {
    /// History snapshot older than this is refetched on appearance.
    static let newContentHistoryTTL: TimeInterval = 10 * 60

    /// Entry point: called on viewWillAppear, after the first feed
    /// page renders and when channels load. Deferred until the initial
    /// feed is on screen so the RSS/history burst never competes with
    /// the startup feed request.
    func refreshNewContentDots() {
        guard !OAuthClient.shared.isAnonymous, !isLoadingInitial else {
            return
        }
        refreshRSSUploads()
        if let fetchedAt = newContentHistoryFetchedAt,
           Date().timeIntervalSince(fetchedAt)
           < SubscriptionsViewController.newContentHistoryTTL {
            recomputeNewContentDots()
            return
        }
        fetchHistoryForNewContent()
    }

    /// Pure recompute from already-loaded inputs; cheap enough to
    /// run on every refresh or local watch event.
    func recomputeNewContentDots() {
        guard let historyIds = newContentHistoryIds else {
            return
        }
        let resolved = NewContentResolver.channelsWithNewContent(
            uploadsByChannel: newContentUploads,
            watchedVideoIds: historyIds.union(locallyWatchedVideoIds)
        )
        guard resolved != newContentChannelIds else {
            return
        }
        newContentChannelIds = resolved
        channelBar.setNewContentChannelIds(resolved)
        AppLog.subs("dots: \(resolved.count) channels")
    }

    /// Optimistic clear when a video is opened in-app; the synced
    /// history confirms it on the next fetch.
    func markWatchedLocally(_ video: Video) {
        guard locallyWatchedVideoIds.insert(video.id).inserted else {
            return
        }
        recomputeNewContentDots()
    }
}

// MARK: - Private Helpers

private extension SubscriptionsViewController {
    /// The service caches per channel, so calling on every appearance
    /// is cheap; only stale channels hit the network.
    func refreshRSSUploads() {
        let ids = subscribedChannels.map { $0.id }
        guard !ids.isEmpty, !isLoadingNewContentRSS else {
            return
        }
        isLoadingNewContentRSS = true
        // A dot means the channel published a proper video, whatever the
        // Shorts setting says — so always the long-form (`UULF`) feed.
        channelRSSService.fetchRecentUploads(
            channelIds: ids,
            includeShorts: false
        ) { [weak self] uploads in
            guard let self else {
                return
            }
            self.isLoadingNewContentRSS = false
            self.newContentUploads = uploads
            self.recomputeNewContentDots()
        }
    }

    func fetchHistoryForNewContent() {
        guard !isLoadingNewContentHistory else {
            return
        }
        isLoadingNewContentHistory = true
        historyService.fetchHistory { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch result {
                case .success(let page):
                    self.loadSecondHistoryPage(after: page)
                case .failure(let error):
                    self.isLoadingNewContentHistory = false
                    AppLog.subs("dots: history fetch failed: \(error)")
                }
            }
        }
    }

    /// One continuation page deepens coverage for binge-watchers;
    /// anything beyond that is diminishing returns.
    func loadSecondHistoryPage(after page: FeedPage) {
        let ids = Set(page.videos.map { $0.id })
        guard let continuation = page.continuation else {
            finishHistoryFetch(ids)
            return
        }
        OAuthClient.shared.validToken { [weak self] result in
            guard case .success(let token) = result else {
                DispatchQueue.main.async {
                    self?.finishHistoryFetch(ids)
                }
                return
            }
            self?.fetchHistoryPage(
                continuation: continuation,
                token: token,
                firstPageIds: ids
            )
        }
    }

    func fetchHistoryPage(
        continuation: String,
        token: String,
        firstPageIds: Set<String>
    ) {
        historyService.fetchHistoryNextPage(
            continuation: continuation,
            token: token
        ) { [weak self] result in
            DispatchQueue.main.async {
                var ids = firstPageIds
                if case .success(let page) = result {
                    ids.formUnion(page.videos.map { $0.id })
                }
                self?.finishHistoryFetch(ids)
            }
        }
    }

    func finishHistoryFetch(_ ids: Set<String>) {
        isLoadingNewContentHistory = false
        newContentHistoryIds = ids
        newContentHistoryFetchedAt = Date()
        AppLog.subs("dots: history ids=\(ids.count)")
        recomputeNewContentDots()
    }
}
