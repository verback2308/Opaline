import Foundation

// MARK: - Shorts of the filtered channel
//
// Picking a channel in the bar loads its Videos tab, which is long-form
// only — the original complaint of issue #34. Its shorts come from the
// channel's `UUSH` Atom feed: one request, exact dates, and the same
// shape the Shorts screen already uses.

extension SubscriptionsViewController {
    func loadChannelShorts(_ channel: SubscribedChannel) {
        channelRSSService.fetchRecentShorts(
            channelIds: [channel.id],
            force: false
        ) { [weak self] byChannel in
            self?.showChannelShorts(byChannel[channel.id] ?? [], of: channel)
        }
    }

    private func showChannelShorts(
        _ entries: [RSSVideoEntry],
        of channel: SubscribedChannel
    ) {
        guard selectedChannel?.id == channel.id else {
            return
        }
        let shorts = entries
            .filter { seenVideoIds.insert($0.videoId).inserted }
            .map { entry -> Video in
                // Exact dates, so the merge below doesn't have to guess them
                // back out of "3d ago".
                sortDatesByVideoId[entry.videoId] = entry.published
                return Video(short: entry, channel: channel)
            }
        guard !shorts.isEmpty else {
            return
        }
        if ShortsGrouping.isEnabled {
            shortsShelf = shorts
        } else {
            videos = mergeSortedVideos(videos, shorts)
        }
        tableView.reloadData()
        AppLog.subs("channel shorts: \(shorts.count) for \(channel.title)")
    }
}
