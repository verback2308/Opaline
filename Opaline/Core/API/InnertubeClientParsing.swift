import Foundation

extension InnertubeClient {
    static func parseWatchPage(
        _ json: [String: Any],
        fallbackVideo fb: Video
    ) -> WatchPage? {
        let ch = parseWatchChannelInfo(json, fallbackVideo: fb)
        let sub = parseSubscribeState(json)
        let likeInfo = parseWatchLikeInfo(json)
        // A queue exists only where the watch request carried a playlistId
        // (`executeWatchNext`) — i.e. the video was opened from a mix or a
        // playlist. Read back from the response alone, the pivot's generic
        // suggestion shelves passed for a queue on ordinary videos: three
        // unrelated videos under a "Mix" header, played next by autoplay.
        let pivot = fb.playlistId == nil ? nil : parsePivotPlaylist(
            json: json,
            currentVideoId: fb.id
        )
        var page = WatchPage(
            video: resolvedVideo(
                fb, from: json, channel: ch
            ),
            description: parseWatchDescription(json),
            channelInfo: ch,
            subscribeButtonText: sub.text,
            isSubscribed: sub.isSubscribed,
            relatedVideos: relatedFromPivot(
                json: json,
                excludingIds: Set([fb.id] + (pivot?.videos.map(\.id) ?? []))
            ),
            likeCount: likeInfo.likeCount,
            likeStatus: likeInfo.likeStatus,
            commentCount: parseCommentCount(json),
            nextVideo: autoplayNextVideo(json),
            playlistTitle: pivot?.title,
            playlistVideos: pivot?.videos,
            queueContinuation: pivot?.continuation,
            shuffleParams: pivot?.shuffleParams
        )
        page.chapters = parseChapters(json)
        return page
    }

    /// The comments engagement panel's header carries the total. Both the
    /// TV and WEB clients put it there; only the comments panel has one.
    static func parseCommentCount(_ json: [String: Any]) -> String? {
        let panels = json["engagementPanels"] as? [[String: Any]] ?? []
        for panel in panels {
            guard let section = panel.digDict(
                "engagementPanelSectionListRenderer"
            ), (section["panelIdentifier"] as? String)?
                .contains("comment") == true,
                let header = section.digDict(
                    JSONKey.header, "engagementPanelTitleHeaderRenderer"
                ) else {
                continue
            }
            if let text = header.runsText("contextualInfo") {
                return text
            }
        }
        return nil
    }

    static func parseWatchLikeInfo(
        _ json: [String: Any]
    ) -> (
        likeCount: String?,
        likeStatus: LikeStatus?
    ) {
        if let renderer = firstRenderer(
            in: json,
            named: "slimVideoActionsRenderer"
        ),
           let buttons = renderer["buttons"]
            as? [[String: Any]] {
            if let result = searchLikeButtons(
                buttons
            ) {
                return result
            }
        }
        if let renderer = firstRenderer(
            in: json,
            named: "likeButtonRenderer"
        ) {
            return parseLikeRenderer(renderer)
        }
        return (nil, nil)
    }

    static func parseCommentsPage(
        _ json: [String: Any]
    ) -> CommentsPage? {
        let updates = json["frameworkUpdates"]
            as? [String: Any]
        let batch = updates?["entityBatchUpdate"]
            as? [String: Any]
        let mutations = batch?["mutations"]
            as? [[String: Any]] ?? []
        let items = commentsItems(in: json)
        let comments = items.compactMap {
            parseComment(item: $0, mutations: mutations)
        }
        let cont = commentsNextContinuation(in: items)
        let title = commentsTitle(in: items)
        guard !comments.isEmpty || cont != nil
        else {
            return nil
        }
        return CommentsPage(
            title: title,
            comments: comments,
            continuation: cont,
            sortOptions: commentsSortOptions(in: items)
        )
    }
}

// MARK: - Private Watch Helpers

private extension InnertubeClient {
    static func resolvedVideo(
        _ fb: Video,
        from json: [String: Any],
        channel: ChannelInfo?
    ) -> Video {
        let meta = parseWatchMetadata(json)
        let name: String
        if let ch = channel?.title, !ch.isEmpty {
            name = ch
        } else {
            name = fb.channelName
        }
        return Video(
            id: fb.id,
            title: meta.title ?? fb.title,
            channelId: channel?.id
                ?? fb.channelId,
            channelName: name,
            channelAvatarURL: channel?.avatarURL
                ?? fb.channelAvatarURL,
            thumbnailURL: fb.thumbnailURL,
            viewCount: meta.viewCountText
                ?? fb.viewCount,
            publishedAt: meta.publishedText
                ?? fb.publishedAt,
            duration: fb.duration,
            isLive: fb.isLive,
            playlistId: fb.playlistId
        )
    }

    static func autoplayNextVideo(
        _ json: [String: Any]
    ) -> Video? {
        let po = json["playerOverlays"]
            as? [String: Any]
        let ovr = po?["playerOverlayRenderer"]
            as? [String: Any]
        let ap = ovr?["autoplay"]
            as? [String: Any]
        let key = "playerOverlayAutoplayRenderer"
        guard let ar = ap?[key]
            as? [String: Any],
              let vid = ar["videoId"] as? String
        else {
            return nil
        }
        return buildAutoplayVideo(
            ar, videoId: vid
        )
    }

    static func buildAutoplayVideo(
        _ ar: [String: Any],
        videoId: String
    ) -> Video {
        let vt = ar["videoTitle"] as? [String: Any]
        let title = vt?["simpleText"] as? String ?? ""
        let byline = ar["byline"] as? [String: Any]
        let channel = byline?["simpleText"] as? String
            ?? (byline?["runs"] as? [[String: Any]])?
                .first?["text"] as? String
            ?? ""
        let runs = byline?["runs"] as? [[String: Any]]
        let nav = runs?.first?["navigationEndpoint"] as? [String: Any]
        let browse = nav?["browseEndpoint"] as? [String: Any]
        let channelId = browse?["browseId"] as? String
        let bg = ar["background"] as? [String: Any]
        let thumbs = bg?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbs?.last?["url"] as? String
            ?? thumbs?.first?["url"] as? String
            ?? AppURLs.YouTube.thumbnailURL(videoId: videoId)
        let viewCount = simpleText(from: ar["shortViewCountText"])
        let publishedAt = simpleText(from: ar["publishedTimeText"])
        let duration = extractOverlayDuration(ar["thumbnailOverlays"])
        return Video(
            id: videoId,
            title: title,
            channelId: channelId,
            channelName: channel,
            channelAvatarURL: nil,
            thumbnailURL: thumbURL,
            viewCount: viewCount,
            publishedAt: publishedAt,
            duration: duration
        )
    }

    private static func extractOverlayDuration(
        _ overlays: Any?
    ) -> String? {
        guard let arr = overlays as? [Any]
        else { return nil }
        for item in arr {
            guard let overlay = item as? [String: Any],
                  let renderer = overlay[
                      "thumbnailOverlayTimeStatusRenderer"
                  ] as? [String: Any],
                  let text = simpleText(from: renderer["text"]),
                  !text.isEmpty
            else { continue }
            return text
        }
        return nil
    }

    static func searchLikeButtons(
        _ buttons: [[String: Any]]
    ) -> (
        likeCount: String?,
        likeStatus: LikeStatus?
    )? {
        let key = "slimMetadataToggleButtonRenderer"
        for btn in buttons {
            if let like = (btn[key]
                as? [String: Any])
                ?? (btn["likeButtonRenderer"]
                    as? [String: Any]) {
                return extractLikeInfo(from: like)
            }
            if let toggle = btn[
                "toggleButtonRenderer"
            ] as? [String: Any] {
                return extractLikeInfo(from: toggle)
            }
        }
        return nil
    }

    static func extractLikeInfo(
        from dict: [String: Any]
    ) -> (
        likeCount: String?,
        likeStatus: LikeStatus?
    ) {
        let status = (dict["likeStatus"]
            as? String)
            .flatMap(LikeStatus.init(rawValue:))
        let count = simpleText(
            from: dict["defaultText"]
        ) ?? simpleText(
            from: dict["likeCountNotliked"]
        )
        return (count, status)
    }

    static func parseLikeRenderer(
        _ renderer: [String: Any]
    ) -> (
        likeCount: String?,
        likeStatus: LikeStatus?
    ) {
        let status = (renderer["likeStatus"]
            as? String)
            .flatMap(LikeStatus.init(rawValue:))
        // `likeCountText` is the TV client's key for the same value; without
        // it a TV watch response parses as having no likes at all.
        let count = simpleText(
            from: renderer["likeCount"]
        ) ?? simpleText(from: renderer["likeCountText"])
            ?? (renderer["likeCountNotliked"] as? String)
        return (count, status)
    }
}
