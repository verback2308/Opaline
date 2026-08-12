import UIKit

/// Every short the subscribed channels published recently, as a grid.
///
/// The subscriptions feed only ever serves the twelve of its Shorts shelf,
/// so this screen is fed from the channels' `UUSH` Atom feeds instead —
/// one request per channel, shorts only, with exact dates and view counts.
/// That fan-out runs when the screen opens, never on the feed's path.
final class SubscriptionShortsViewController: VideosViewController {
    /// Rows are cheap to build but the list runs to hundreds of items —
    /// the grid takes them a screenful at a time as it scrolls.
    private static let pageSize = 30

    override var usesShortsGrid: Bool { true }
    override var groupsByShelf: Bool { false }

    /// Same tiling as the channel's Shorts tab.
    override var columns: Int {
        UIDevice.current.userInterfaceIdiom == .phone ? 3 : 6
    }

    private let rssService: ChannelRSSFeedService
    private let channels: [SubscribedChannel]
    /// Fetched, sorted, not yet handed to the grid.
    private var pending: [Video] = []
    /// The base class pages on a continuation token; here the "next page"
    /// is already in memory, so the token is just a "there is more" flag.
    private var localContinuation: String? {
        pending.isEmpty ? nil : "local"
    }

    init(
        channels: [SubscribedChannel],
        rssService: ChannelRSSFeedService,
        channelViewControllerFactory: @escaping (
            String, String
        ) -> UIViewController,
        videoRouter: VideoRouter = .shared
    ) {
        self.channels = channels
        self.rssService = rssService
        super.init(
            channelViewControllerFactory: channelViewControllerFactory,
            videoRouter: videoRouter
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "shorts.shelf.title".localized
        load()
    }

    override func handleRefresh() {
        load(force: true)
    }

    private func load(force: Bool = false) {
        var byId: [String: SubscribedChannel] = [:]
        channels.forEach { byId[$0.id] = $0 }
        rssService.fetchRecentShorts(
            channelIds: channels.map { $0.id },
            force: force
        ) { [weak self] byChannel in
            self?.show(Self.videos(from: byChannel, channels: byId))
        }
    }

    /// Every feed is in and sorted by then — the grid is built once and
    /// only ever grows downwards, so nothing moves under a thumb.
    private func show(_ videos: [Video]) {
        collectionView?.refreshControl?.endRefreshing()
        spinner.stopAnimating()
        AppLog.subs("rss shorts screen: \(videos.count) videos")
        pending = Array(videos.dropFirst(Self.pageSize))
        setPage(
            FeedPage(
                videos: Array(videos.prefix(Self.pageSize)),
                continuation: localContinuation
            )
        )
    }

    override func handleLoadMore() {
        let slice = Array(pending.prefix(Self.pageSize))
        pending.removeFirst(slice.count)
        appendPage(
            FeedPage(videos: slice, continuation: localContinuation)
        )
    }
}

// MARK: - RSS mapping

private extension SubscriptionShortsViewController {
    /// Newest first across all channels. Atom gives everything the card
    /// shows except the duration, which a shorts card doesn't show; the
    /// poster comes from the video id.
    private static func videos(
        from byChannel: [String: [RSSVideoEntry]],
        channels: [String: SubscribedChannel]
    ) -> [Video] {
        byChannel
            .flatMap { channelId, entries -> [(Date, Video)] in
                guard let channel = channels[channelId] else {
                    return []
                }
                return entries.map {
                    ($0.published, Video(short: $0, channel: channel))
                }
            }
            .sorted { $0.0 > $1.0 }
            .map { $0.1 }
    }
}
