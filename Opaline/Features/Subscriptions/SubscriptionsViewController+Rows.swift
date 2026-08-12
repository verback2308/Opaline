import UIKit

/// A row of the subscriptions list: either a video, or the shelf holding the
/// feed's shorts.
enum FeedRow {
    case video(Video)
    case shortsShelf([Video])
}

extension SubscriptionsViewController {
    /// The shelf sits on top: the feed serves its shorts in one go, in the
    /// first response, so there is nothing to spread further down.
    func rebuildRows() {
        let shelf: [FeedRow] = shortsShelf.isEmpty
            ? [] : [.shortsShelf(shortsShelf)]
        rows = shelf + videos.map(FeedRow.video)
    }
}

// MARK: - Data source

extension SubscriptionsViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isLoadingInitial
            ? SubscriptionsViewController.skeletonCount
            : rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if !isLoadingInitial, case let .shortsShelf(shorts) = rows[indexPath.row] {
            return shortsShelfCell(for: indexPath, shorts: shorts)
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: SubscriptionVideoCell.reuseId,
            for: indexPath
        ) as? SubscriptionVideoCell else {
            return UITableViewCell()
        }
        if isLoadingInitial {
            cell.configureSkeleton()
            return cell
        }
        guard case let .video(video) = rows[indexPath.row] else {
            return cell
        }
        cell.configure(with: video)
        attachHandlers(to: cell, video: video)
        return cell
    }

    private func shortsShelfCell(
        for indexPath: IndexPath,
        shorts: [Video]
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ShortsShelfCell.reuseId, for: indexPath
        ) as? ShortsShelfCell else {
            return UITableViewCell()
        }
        cell.configure(with: shorts)
        cell.onSeeAll = { [weak self] in
            self?.openAllShorts()
        }
        cell.onSelect = { [weak self] index in
            guard let self, index < shorts.count else {
                return
            }
            self.videoRouter.open(
                video: shorts[index], from: self, shorts: .pool(shorts)
            )
        }
        return cell
    }

    /// The feed's twelve are all it has; the full list comes from the
    /// channels' own feeds, fetched only when this screen opens. Under a
    /// channel filter the screen stays scoped to that one channel.
    private func openAllShorts() {
        navigationController?.pushViewController(
            SubscriptionShortsViewController(
                channels: selectedChannel.map { [$0] } ?? subscribedChannels,
                rssService: channelRSSService,
                channelViewControllerFactory: channelViewControllerFactory,
                videoRouter: videoRouter
            ),
            animated: true
        )
    }

    private func attachHandlers(to cell: SubscriptionVideoCell, video: Video) {
        cell.onChannelTap = { [weak self] in
            guard let self,
                  let channelId = video.channelId
            else {
                return
            }
            self.navigationController?.pushViewController(
                self.channelViewControllerFactory(
                    channelId,
                    video.channelName
                ),
                animated: true
            )
        }
        cell.onMenuTap = { [weak self] anchor in
            guard let self else {
                return
            }
            VideoActionMenu.present(video: video, from: self, anchor: anchor)
        }
    }
}

// MARK: - Delegate

extension SubscriptionsViewController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else {
            return
        }
        topBarHider.handleScroll(scrollView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !isLoadingInitial,
              case let .video(video) = rows[indexPath.row]
        else {
            return
        }
        markWatchedLocally(video)
        videoRouter.open(video: video, from: self)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard !isLoadingInitial else {
            return SubscriptionVideoCell.rowHeight(
                forWidth: tableView.bounds.width, title: ""
            )
        }
        switch rows[indexPath.row] {
        case .shortsShelf:
            return ShortsShelfCell.rowHeight
        case let .video(video):
            return SubscriptionVideoCell.rowHeight(
                forWidth: tableView.bounds.width, title: video.title
            )
        }
    }

    func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard !isLoadingInitial,
              !isLoadingMore,
              continuationToken != nil,
              indexPath.row >= rows.count - 4
        else { return }

        isLoadingMore = true
        loadMore()
    }
}
