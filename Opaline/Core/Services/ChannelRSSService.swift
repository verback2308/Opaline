import Foundation

/// Which of a channel's Atom feeds to read: everything, the long-form
/// `UULF` system playlist, or the Shorts-only `UUSH` one.
enum RSSFeedVariant {
    case all
    case longForm
    case shorts
}

/// One video entry from a channel's public Atom feed.
struct RSSVideoEntry {
    let videoId: String
    let title: String
    let published: Date
    /// From `media:statistics` — a snapshot, not live, but the feed's.
    let viewCount: Int?
}

/// Fetches the public per-channel Atom feeds (`/feeds/videos.xml`) used
/// to detect fresh uploads for the new-content dots (issue #13).
/// Anonymous, chronological, immune to the relevance ranking that broke
/// the TVHTML5 subscriptions feed as a freshness signal.
protocol ChannelRSSFeedService: AnyObject {
    /// Fetches recent uploads for every channel id; failed channels are
    /// omitted from the result. When `includeShorts` is false the
    /// long-form-only `UULF` playlist feed is used (full feed as
    /// fallback). Completion fires on the main queue.
    func fetchRecentUploads(
        channelIds: [String],
        includeShorts: Bool,
        completion: @escaping ([String: [RSSVideoEntry]]) -> Void
    )

    /// Recent shorts per channel, straight from the `UUSH` playlist feed —
    /// one request per channel, no guessing. Channels without that feed are
    /// omitted. Completion fires on the main queue, once every feed is in:
    /// the list is date-sorted, so a partial answer would reshuffle the
    /// screen under the reader. `force` drops the cached feeds first — what
    /// pull-to-refresh means.
    func fetchRecentShorts(
        channelIds: [String],
        force: Bool,
        completion: @escaping ([String: [RSSVideoEntry]]) -> Void
    )
}

final class ChannelRSSService: ChannelRSSFeedService {
    /// Internal so the fetching extension (another file) can fill it.
    struct CacheSlot {
        let entries: [RSSVideoEntry]
        let fetchedAt: Date
    }

    /// Per-channel snapshots younger than this are served from memory.
    static let cacheTTL: TimeInterval = 30 * 60

    /// Nothing-came-back is cached too — a channel with no `UUSH` playlist
    /// 404s on every open otherwise — but briefly, so a network blip can't
    /// hide a channel for the full TTL.
    static let emptyCacheTTL: TimeInterval = 5 * 60

    /// Sliding-window cap so a cold start with many subscriptions
    /// doesn't burst dozens of connections and starve the feed request.
    static let maxConcurrentFetches = 4

    let transport: HTTPTransport
    let queue = DispatchQueue(label: "ChannelRSSService")
    var cache: [String: CacheSlot] = [:]

    init(transport: HTTPTransport = ServiceContainer.mediaTransport) {
        self.transport = transport
    }

    func fetchRecentUploads(
        channelIds: [String],
        includeShorts: Bool,
        completion: @escaping ([String: [RSSVideoEntry]]) -> Void
    ) {
        fetch(
            channelIds: channelIds,
            variant: includeShorts ? .all : .longForm,
            completion: completion
        )
    }

    func fetchRecentShorts(
        channelIds: [String],
        force: Bool,
        completion: @escaping ([String: [RSSVideoEntry]]) -> Void
    ) {
        if force {
            queue.async { self.invalidate(channelIds, variant: .shorts) }
        }
        fetch(channelIds: channelIds, variant: .shorts) { shorts in
            let count = shorts.values.reduce(0) { $0 + $1.count }
            AppLog.subs("rss shorts: \(count) in \(shorts.count) channels")
            completion(shorts)
        }
    }

    private func fetch(
        channelIds: [String],
        variant: RSSFeedVariant,
        completion: @escaping ([String: [RSSVideoEntry]]) -> Void
    ) {
        queue.async {
            self.fetchOnQueue(
                channelIds: channelIds,
                variant: variant,
                completion: completion
            )
        }
    }
}

/// Mutable state of one `fetchRecentUploads` fan-out; only touched on
/// the service queue.
final class FetchBatch {
    var pending: [String]
    var results: [String: [RSSVideoEntry]]
    var active = 0
    let variant: RSSFeedVariant
    let completion: ([String: [RSSVideoEntry]]) -> Void

    init(
        pending: [String],
        results: [String: [RSSVideoEntry]],
        variant: RSSFeedVariant,
        completion: @escaping ([String: [RSSVideoEntry]]) -> Void
    ) {
        self.pending = pending
        self.results = results
        self.variant = variant
        self.completion = completion
    }
}
