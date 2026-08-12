import Foundation

// MARK: - Shelf Parsing
//
// TV shelves (horizontalListRenderer rows) carry a title and their
// own "more of this row" continuation. Browsing one returns
// continuationContents.horizontalListContinuation with ~10 tiles
// and a next token; the Recommended shelf is effectively endless.

/// Collects a section list's videos with their shelf partition and
/// per-shelf continuation tokens.
struct ShelfAccumulator {
    var videos: [Video] = []
    var shelves: [FeedShelf] = []
    var continuations: [ShelfContinuation] = []
}

extension InnertubeClient {
    static let shelfListRendererKeys = [
        RendererKey.horizontalList,
        RendererKey.verticalList,
        RendererKey.grid
    ]

    static func appendSection(
        _ section: [String: Any],
        showShorts: Bool,
        into acc: inout ShelfAccumulator
    ) {
        guard let shelf = section["shelfRenderer"]
            as? [String: Any],
            let sc = shelf["content"] as? [String: Any]
        else {
            AppLog.innertube(
                "sectionList: skipping section"
                    + " keys=\(section.keys.sorted())"
            )
            return
        }
        let isShorts = isShortsShelf(shelf)
        if !showShorts && isShorts {
            return
        }
        let title = shelfTitle(shelf)
        let before = acc.videos.count
        appendShelfVideos(from: sc, into: &acc.videos)
        // The TV client has no shorts renderer — a short arrives as an
        // ordinary tile and the SHELF is the only signal that it is one.
        if isShorts {
            for index in before ..< acc.videos.count {
                acc.videos[index].isShort = true
            }
        }
        let added = acc.videos.count - before
        if added > 0 {
            recordShelf(title, added: added, content: sc, into: &acc)
        }
        AppLog.innertube(
            "shelf '\(title ?? "?")': +\(added) videos shorts=\(isShorts)"
        )
    }

    /// Only video shelves are recorded — channel/mix shelves would
    /// page through zero-video responses forever if drained.
    private static func recordShelf(
        _ title: String?,
        added: Int,
        content: [String: Any],
        into acc: inout ShelfAccumulator
    ) {
        let token = shelfContinuationToken(in: content)
        acc.shelves.append(
            FeedShelf(title: title, count: added, continuation: token)
        )
        if let token {
            acc.continuations.append(
                ShelfContinuation(title: title, token: token)
            )
        }
    }

    static func parseHorizontalListCont(
        _ hlc: [String: Any]
    ) -> FeedPage {
        let items = hlc[JSONKey.items]
            as? [[String: Any]] ?? []
        let videos = VideoRendererParserChain
            .videos(from: items)
        AppLog.innertube(
            "shelf continuation: \(videos.count) videos"
        )
        return FeedPage(
            videos: videos,
            continuation: shelfNextContToken(hlc)
        )
    }
}

// MARK: - Private Shelf Helpers

private extension InnertubeClient {
    static func shelfTitle(
        _ shelf: [String: Any]
    ) -> String? {
        if let title = shelf.runsText("title") {
            return title
        }
        let header = shelf.digDict(
            "headerRenderer", "shelfHeaderRenderer"
        )
        if let title = header?.runsText("title") {
            return title
        }
        let lockup = header?.digDict(
            "avatarLockup", "avatarLockupRenderer"
        )
        return lockup?.runsText("title")
    }

    static func isShortsShelf(
        _ shelf: [String: Any]
    ) -> Bool {
        let lockup = shelf.digDict(
            "headerRenderer",
            "shelfHeaderRenderer",
            "avatarLockup",
            "avatarLockupRenderer"
        )
        let icon = lockup?["icon"] as? [String: Any]
        if let iconType = icon?["iconType"] as? String,
           iconType.contains("SHORTS") {
            return true
        }
        let title = lockup?["title"] as? [String: Any]
        let runs = title?["runs"] as? [[String: Any]]
        let text = runs?.first?["text"] as? String
        return text?.lowercased() == "shorts"
    }

    static func appendShelfVideos(
        from shelfContent: [String: Any],
        into videos: inout [Video]
    ) {
        for key in shelfListRendererKeys {
            let rd = shelfContent[key]
                as? [String: Any]
            if let items = rd?["items"]
                as? [[String: Any]] {
                videos.append(
                    contentsOf:
                        VideoRendererParserChain
                        .videos(from: items)
                )
            }
        }
    }

    static func shelfContinuationToken(
        in shelfContent: [String: Any]
    ) -> String? {
        for key in shelfListRendererKeys {
            if let rd = shelfContent[key]
                as? [String: Any],
                let token = shelfNextContToken(rd) {
                return token
            }
        }
        return nil
    }

    static func shelfNextContToken(
        _ container: [String: Any]
    ) -> String? {
        let conts = container[JSONKey.continuations]
            as? [[String: Any]]
        let next = conts?.first?[
            "nextContinuationData"
        ] as? [String: Any]
        return next?[JSONKey.continuation]
            as? String
    }
}
