import Foundation

// MARK: - Fetching
//
// The fan-out: cache partition, the sliding window of in-flight
// requests, and the per-variant feed URLs.

extension ChannelRSSService {
    /// Keyed per variant so toggling the Shorts setting never serves
    /// entries fetched for another feed.
    func cacheKey(_ channelId: String, variant: RSSFeedVariant) -> String {
        let prefix: String
        switch variant {
        case .all:
            prefix = "all|"
        case .longForm:
            prefix = "lf|"
        case .shorts:
            prefix = "sh|"
        }
        return prefix + channelId
    }

    /// Forgets the cached feeds so the next fetch goes to the network.
    /// On-queue.
    func invalidate(_ channelIds: [String], variant: RSSFeedVariant) {
        for id in channelIds {
            cache[cacheKey(id, variant: variant)] = nil
        }
    }

    /// Splits ids into cache hits and stale/missing ones. On-queue.
    func partitionCached(
        _ channelIds: [String],
        variant: RSSFeedVariant
    ) -> (cached: [String: [RSSVideoEntry]], stale: [String]) {
        var cached: [String: [RSSVideoEntry]] = [:]
        var stale: [String] = []
        let now = Date()
        for id in Set(channelIds) {
            let slot = cache[cacheKey(id, variant: variant)]
            let ttl = (slot?.entries.isEmpty ?? false)
                ? ChannelRSSService.emptyCacheTTL
                : ChannelRSSService.cacheTTL
            if let slot, now.timeIntervalSince(slot.fetchedAt) < ttl {
                cached[id] = slot.entries
            } else {
                stale.append(id)
            }
        }
        return (cached, stale)
    }

    func fetchOnQueue(
        channelIds: [String],
        variant: RSSFeedVariant,
        completion: @escaping ([String: [RSSVideoEntry]]) -> Void
    ) {
        let (cached, stale) = partitionCached(
            channelIds,
            variant: variant
        )
        guard !stale.isEmpty else {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        AppLog.subs("rss: fetching \(stale.count) channels")
        let started = Date()
        let count = stale.count
        let batch = FetchBatch(
            pending: stale,
            results: cached,
            variant: variant
        ) { results in
            let ms = Int(Date().timeIntervalSince(started) * 1_000)
            AppLog.subs("rss: \(count) channels done in \(ms)ms")
            completion(results)
        }
        startNextFetches(in: batch)
    }

    /// Keeps at most `maxConcurrentFetches` requests in flight,
    /// starting the next one as each completes. On-queue.
    func startNextFetches(in batch: FetchBatch) {
        while batch.active < ChannelRSSService.maxConcurrentFetches,
              !batch.pending.isEmpty {
            let id = batch.pending.removeFirst()
            batch.active += 1
            fetchChannel(id, variant: batch.variant) { entries in
                batch.active -= 1
                let key = self.cacheKey(id, variant: batch.variant)
                self.cache[key] = CacheSlot(
                    entries: entries ?? [],
                    fetchedAt: Date()
                )
                if let entries {
                    batch.results[id] = entries
                }
                self.startNextFetches(in: batch)
            }
        }
        if batch.active == 0, batch.pending.isEmpty {
            let results = batch.results
            DispatchQueue.main.async { batch.completion(results) }
        }
    }

    /// System-playlist feed per variant, with the full channel feed as the
    /// fallback for channels where that playlist 404s — except for Shorts,
    /// where falling back would serve the whole channel as shorts.
    /// Calls back on `queue`; nil when nothing usable comes back.
    func fetchChannel(
        _ channelId: String,
        variant: RSSFeedVariant,
        completion: @escaping ([RSSVideoEntry]?) -> Void
    ) {
        let fullFeedURL = AppURLs.YouTube.channelRSSFeedURL(
            channelId: channelId
        )
        switch variant {
        case .all:
            fetchFeed(url: fullFeedURL, completion: completion)
        case .shorts:
            fetchFeed(
                url: AppURLs.YouTube.channelShortsRSSFeedURL(
                    channelId: channelId
                ),
                completion: completion
            )
        case .longForm:
            guard let longFormURL = AppURLs.YouTube.channelLongFormRSSFeedURL(
                channelId: channelId
            ) else {
                fetchFeed(url: fullFeedURL, completion: completion)
                return
            }
            fetchFeed(url: longFormURL) { entries in
                if let entries {
                    completion(entries)
                } else {
                    self.fetchFeed(url: fullFeedURL, completion: completion)
                }
            }
        }
    }

    /// Calls back on `queue`; nil on transport or parse failure.
    func fetchFeed(
        url: URL?,
        completion: @escaping ([RSSVideoEntry]?) -> Void
    ) {
        guard let url else {
            completion(nil)
            return
        }
        let request = HTTPRequest(
            method: .get,
            url: url,
            sendsCookies: false
        )
        transport.send(request, cancellationToken: nil) { result in
            self.queue.async {
                guard case .success(let response) = result,
                      response.status == 200
                else {
                    completion(nil)
                    return
                }
                // Parsing runs on the service queue, so a hundred feeds
                // parse one after another — worth knowing what one costs
                // before deciding this needs a server.
                let t0 = Date()
                let entries = ChannelRSSParser.parse(response.data)
                let ms = Int(Date().timeIntervalSince(t0) * 1_000)
                AppLog.subs(
                    "rss parse \(ms)ms entries=\(entries?.count ?? -1)"
                        + " bytes=\(response.data.count)"
                )
                completion(entries)
            }
        }
    }
}
