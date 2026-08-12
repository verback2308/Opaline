import UIKit

// MARK: - Setup

extension SubscriptionsViewController {
    func loadInitialContent() {
        if OAuthClient.shared.isAnonymous {
            AppLog.subs("anonymous → skip load")
            spinner.stopAnimating()
            showSignInPrompt(true)
            return
        }
        loadSubscribedChannels()
        cache.loadSubscriptionsFeed { [weak self] cachedPage in
            self?.handleCachedSubscriptions(cachedPage)
        }
    }

    func setupSignInPrompt() {
        let prompt = SignInEmptyStateView(
            message: "subscriptions.signIn".localized
        )
        prompt.isHidden = true
        prompt.onSignIn = { [weak self] in
            self?.toolbarOpenProfile()
        }
        view.addSubview(prompt)
        NSLayoutConstraint.activate([
            prompt.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            prompt.centerYAnchor.constraint(
                equalTo: view.centerYAnchor,
                constant: -40
            ),
            prompt.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 40
            ),
            prompt.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -40
            )
        ])
        signInPrompt = prompt
    }

    func showSignInPrompt(_ show: Bool) {
        signInPrompt?.isHidden = !show
        tableView.isHidden = show
    }

    func setupTableView() {
        tableView.register(
            SubscriptionVideoCell.self,
            forCellReuseIdentifier:
                SubscriptionVideoCell.reuseId
        )
        tableView.register(
            ShortsShelfCell.self,
            forCellReuseIdentifier: ShortsShelfCell.reuseId
        )
        tableView.dataSource = self
        tableView.delegate = self
        // Heights come from `heightForRowAt`; the estimate keeps the table
        // asking only for visible rows instead of all of them on reload.
        tableView.estimatedRowHeight = 220
        tableView.separatorStyle = .none
        tableView.translatesAutoresizingMaskIntoConstraints =
            false
        let refresh = UIRefreshControl()
        refresh.addTarget(
            self,
            action: #selector(handleRefresh),
            for: .valueChanged
        )
        tableView.refreshControl = refresh
        view.addSubview(tableView)
        pinToEdges(tableView, of: view)
    }

    func setupSpinner() {
        spinner.translatesAutoresizingMaskIntoConstraints =
            false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            spinner.centerYAnchor.constraint(
                equalTo: view.centerYAnchor
            )
        ])
        spinner.startAnimating()
    }
}

// MARK: - Data Loading

extension SubscriptionsViewController {
    func loadFeed() {
        let t0 = Date()
        AppLog.subs("network fetch start")
        service.fetchSubscriptionFeed { [weak self] result in
            self?.handleFeedResult(result, since: t0)
        }
    }

    func loadMore() {
        guard let continuation = continuationToken else {
            finishLoadingMore()
            return
        }
        if let channel = selectedChannel {
            loadMoreChannelVideos(
                continuation: continuation,
                channelId: channel.id
            )
            return
        }
        service.fetchSubscriptionsNextPage(
            continuation: continuation
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.selectedChannel == nil else {
                    self?.finishLoadingMore()
                    return
                }
                switch result {
                case let .success(page):
                    self.appendPage(page)
                case let .failure(error):
                    self.finishLoadingMore()
                    AppLog.subs("pagination error: \(error)")
                    self.revalidateOnceAfterStaleToken()
                }
            }
        }
    }

    func setPage(_ page: FeedPage) {
        isLoadingInitial = false
        seenVideoIds = []
        sortDatesByVideoId = [:]
        videos = []
        shortsShelf = []
        appendPage(page)
        refreshNewContentDots()
    }

    func appendPage(_ page: FeedPage) {
        let fresh = page.videos.filter {
            seenVideoIds.insert($0.id).inserted
        }
        // With grouping on the shorts are split off into their own shelf so
        // every consumer below — row heights, taps — sees a list without
        // them; off, they stay in the list as ordinary videos.
        let grouping = ShortsGrouping.isEnabled
        if grouping {
            shortsShelf.append(contentsOf: fresh.filter { $0.isShort })
        }
        let newVideos = grouping ? fresh.filter { !$0.isShort } : fresh
        if !newVideos.isEmpty {
            videos.append(contentsOf: newVideos)
        }
        continuationToken = page.continuation
        isLoadingMore = false
        tableView.reloadData()
    }

    func finishLoadingMore() {
        isLoadingMore = false
    }

    /// Skipping revalidation on launch means the cached continuation can be
    /// hours old; the first dead one is the signal to refetch, so scrolling
    /// never dead-ends. Once per session — a genuinely offline device
    /// shouldn't retry on every attempt.
    func revalidateOnceAfterStaleToken() {
        guard !didRevalidateAfterStaleToken else {
            return
        }
        didRevalidateAfterStaleToken = true
        AppLog.subs("stale continuation → revalidating")
        loadFeed()
    }
}

// MARK: - Private Helpers

private extension SubscriptionsViewController {
    func handleCachedSubscriptions(
        _ cachedPage: FeedPage?,
        firstVisit: Bool = true
    ) {
        guard selectedChannel == nil else {
            return
        }
        if let cachedPage {
            AppLog.subs(
                "cache-hit → showing "
                    + "\(cachedPage.videos.count)"
                    + " videos"
            )
            isLoadingInitial = false
            spinner.stopAnimating()
            setPage(cachedPage)
            harvestChannels(from: cachedPage)
            // Revalidating replaces the whole feed and rebuilds the screen
            // (see HomeViewController+Feed.swift for the same rule) — skip
            // it while the cache is recent; background refresh keeps it
            // that way, pull-to-refresh forces it, and a stale
            // continuation triggers it lazily via revalidateOnceAfterStaleToken.
            let age = cache.feedAge("subscriptions") ?? .greatestFiniteMagnitude
            guard age >= AppCache.feedRevalidateAfter else {
                AppLog.subs("cache is \(Int(age / 60))m old → no revalidation")
                return
            }
            AppLog.subs("revalidating feed in background")
            loadFeed()
        } else {
            AppLog.subs("no cache → network")
            loadFeed()
        }
    }

    func handleFeedResult(
        _ result: Result<FeedPage, Error>,
        since t0: Date
    ) {
        DispatchQueue.main.async {
            let ms = Int(
                Date().timeIntervalSince(t0) * 1_000
            )
            self.spinner.stopAnimating()
            self.tableView.refreshControl?
                .endRefreshing()
            switch result {
            case let .success(page):
                AppLog.subs(
                    "network done \(ms)ms"
                        + " videos=\(page.videos.count)"
                )
                self.applyFeedPage(page)
            case let .failure(error):
                AppLog.subs(
                    "network failed \(ms)ms: \(error)"
                )
                self.finishLoadingMore()
                if case APIError.unauthorized = error {
                    self.isLoadingInitial = false
                    self.showSignInPrompt(true)
                    self.tableView.reloadData()
                }
            }
        }
    }

    func applyFeedPage(_ page: FeedPage) {
        showSignInPrompt(false)
        cache.setSubscriptionsFeed(page)
        if selectedChannel == nil {
            setPage(page)
        } else {
            stashedVideos = page.videos
            stashedContinuation = page.continuation
            stashedSeenVideoIds = Set(page.videos.map { $0.id })
        }
        harvestChannels(from: page)
    }

    func pinToEdges(
        _ child: UIView, of parent: UIView
    ) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(
                equalTo: parent.topAnchor
            ),
            child.leadingAnchor.constraint(
                equalTo: parent.leadingAnchor
            ),
            child.trailingAnchor.constraint(
                equalTo: parent.trailingAnchor
            ),
            child.bottomAnchor.constraint(
                equalTo: parent.bottomAnchor
            )
        ])
    }
}
