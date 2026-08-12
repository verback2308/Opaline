import Foundation

// MARK: - VideoRendererParser

/// A single link in the renderer chain. Each parser handles one renderer type
/// (e.g. "tileRenderer", "videoRenderer") from an item dictionary.
///
/// Item dictionaries look like: {"tileRenderer": {...}} or {"videoRenderer": {...}}.
protocol VideoRendererParser {
    /// Returns a `Video` if this parser can handle the item, nil otherwise.
    func video(from item: [String: Any]) -> Video?
}

// MARK: - VideoRendererParserChain

/// Tries each registered VideoRendererParser in priority order and returns the
/// first non-nil result. Replaces repeated if/else chains in browse parsing:
///
///   Before:
///     if let tile = item["tileRenderer"]     { parseTileRenderer(tile) }
///     if let vr   = item["videoRenderer"]    { parseWebVideoRenderer(vr) }
///     if let vr   = item["compactVideoRenderer"] { parseWebVideoRenderer(vr) }
///     if let ri   = item["richItemRenderer"] { ... vr = ri["content"]["videoRenderer"] ... }
///
///   After:
///     VideoRendererParserChain.shared.video(from: item)
///
enum VideoRendererParserChain {
    /// Renderer keys that can carry a short behind ordinary video chrome.
    private static let videoRendererKeys = [
        RendererKey.video,
        RendererKey.compactVideo,
        RendererKey.tile,
        "gridVideoRenderer"
    ]

    private static let parsers: [VideoRendererParser] = [
        TileVideoRendererParser(),
        DirectVideoRendererParser(),
        CompactVideoRendererParser(),
        GridVideoRendererParser(),
        RichItemVideoRendererParser(),
        LockupViewModelVideoParser(),
        RadioRendererParser(),
        PlaylistRendererParser(),
        ReelItemVideoRendererParser(),
        ShortsLockupVideoParser()
    ]

    static func video(from item: [String: Any]) -> Video? {
        parsers.lazy.compactMap { $0.video(from: item) }.first
    }

    /// Returns true if `item` is a YouTube Short.
    /// A short reaches us in three shapes, depending on client and surface:
    ///   • a dedicated `reelItemRenderer` / `shortsLockupViewModel`
    ///   • either of those wrapped in a `richItemRenderer`
    ///   • an ordinary video renderer (web/compact/grid/tile) whose
    ///     navigation points at a `reelWatchEndpoint`, or whose overlay is
    ///     styled SHORTS
    ///
    /// TV subscription tiles carry none of these — nothing in the tile tells
    /// a short from an hour-long stream (contentType, style and
    /// ustreamerConfig are identical, device-checked 2026-08-11). There, only
    /// the Shorts shelf gives them away; see `InnertubeClient.appendSection`.
    static func isShortFeedItem(_ item: [String: Any]) -> Bool {
        let content = item.digDict(RendererKey.richItem, JSONKey.content)
            ?? item
        if content["reelItemRenderer"] != nil
            || content["shortsLockupViewModel"] != nil {
            return true
        }
        if videoRendererKeys.contains(where: { key in
            (content[key] as? [String: Any])
                .map(navigatesToReel) ?? false
        }) {
            return true
        }
        return extractOverlays(from: item).contains { overlay in
            (overlay[RendererKey.thumbnailOverlayTimeStatus]
                as? [String: Any])?["style"] as? String == "SHORTS"
        }
    }

    /// True when any of the renderer's tap commands opens /shorts/….
    private static func navigatesToReel(_ renderer: [String: Any]) -> Bool {
        ["navigationEndpoint", "onSelectCommand", "onTap"].contains { key in
            (renderer[key] as? [String: Any])?["reelWatchEndpoint"] != nil
        }
    }

    /// Extracts a continuation token from a `continuationItemRenderer` item, if present.
    static func continuation(from item: [String: Any]) -> String? {
        guard let renderer = item["continuationItemRenderer"] as? [String: Any],
              let ct = renderer["continuationEndpoint"] as? [String: Any],
              let cmd = ct["continuationCommand"] as? [String: Any],
              let token = cmd["token"] as? String
        else {
            return nil
        }
        return token
    }

    /// Convenience: maps a list of items to videos, skipping unrecognised items.
    /// Shorts are excluded unless the showShorts setting is on.
    /// Also extracts inline watch progress from thumbnail overlays.
    static func videos(from items: [[String: Any]]) -> [Video] {
        items.compactMap { item in
            if let parsed = video(from: item) {
                storeInlineProgress(
                    item: item, videoId: parsed.id
                )
                return kept(marked(parsed, item: item))
            }
            return nil
        }
    }

    /// Convenience: maps items to videos AND extracts the first continuation token found.
    /// Shorts are excluded unless the showShorts setting is on.
    /// Also extracts inline watch progress from thumbnail overlays.
    static func parse(items: [[String: Any]]) -> (videos: [Video], continuation: String?) {
        var videos: [Video] = []
        var continuation: String?
        for item in items {
            if let parsed = video(from: item) {
                storeInlineProgress(
                    item: item, videoId: parsed.id
                )
                if let kept = kept(marked(parsed, item: item)) {
                    videos.append(kept)
                }
            } else if continuation == nil,
                      let token = Self.continuation(from: item) {
                continuation = token
            }
        }
        return (videos, continuation)
    }

    /// Extracts `percentDurationWatched` from
    /// `thumbnailOverlayResumePlaybackRenderer` in a raw
    /// browse item and stores it in WatchProgressStore.
    private static func storeInlineProgress(
        item: [String: Any],
        videoId: String
    ) {
        let overlays = extractOverlays(from: item)
        guard let frac = extractResumeFraction(
            overlays
        ),
            frac > 0.03
        else {
            return
        }
        WatchProgressStore.shared.setFraction(
            videoId: videoId, fraction: frac
        )
    }

    private static func rendererOverlays(
        _ dict: [String: Any]?
    ) -> [[String: Any]] {
        dict?["thumbnailOverlays"]
            as? [[String: Any]] ?? []
    }

    private static func extractOverlays(
        from item: [String: Any]
    ) -> [[String: Any]] {
        if let ri = item[RendererKey.richItem]
            as? [String: Any],
           let content = ri[JSONKey.content]
            as? [String: Any] {
            return rendererOverlays(
                content[RendererKey.video]
                    as? [String: Any]
            )
        }
        if let vr = item[RendererKey.video]
            as? [String: Any] {
            return rendererOverlays(vr)
        }
        if let vr = item[RendererKey.compactVideo]
            as? [String: Any] {
            return rendererOverlays(vr)
        }
        if let vr = item["gridVideoRenderer"]
            as? [String: Any] {
            return rendererOverlays(vr)
        }
        if let tile = item[RendererKey.tile]
            as? [String: Any] {
            let hdr = tile.digDict(
                JSONKey.header,
                RendererKey.tileHeader
            )
            return rendererOverlays(hdr)
        }
        return []
    }

    private static func extractResumeFraction(
        _ overlays: [[String: Any]]
    ) -> Double? {
        let keys = [
            "thumbnailOverlayResumePlaybackRenderer",
            RendererKey.thumbnailOverlayTimeStatus
        ]
        for overlay in overlays {
            for key in keys {
                guard let renderer = overlay[key]
                    as? [String: Any]
                else {
                    continue
                }
                if let raw = renderer[
                    "percentDurationWatched"
                ] as? Double {
                    return raw > 1
                        ? raw / 100.0 : raw
                }
            }
        }
        return nil
    }

    // MARK: - Private

    /// Flags the video as a short when its raw item says so — the renderer
    /// parsers each see only their own shape, this sees the item every feed
    /// passes through, so no surface can leak an unflagged short.
    private static func marked(
        _ video: Video, item: [String: Any]
    ) -> Video {
        guard !video.isShort, isShortFeedItem(item) else {
            return video
        }
        var short = video
        short.isShort = true
        return short
    }

    /// Drops shorts when the setting is off. Filtering the parsed video rather
    /// than the raw item catches the ones flagged by their shelf as well.
    private static func kept(_ video: Video) -> Video? {
        let showShorts = UserDefaults.standard.bool(
            forKey: UserDefaultsKeys.Feed.showShorts
        )
        return !showShorts && video.isShort ? nil : video
    }
}
