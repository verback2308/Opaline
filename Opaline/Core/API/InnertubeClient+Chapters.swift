import Foundation

// MARK: - Chapters

extension InnertubeClient {
    /// The TV client ships chapters as a `macroMarkersListEntity` mutation in
    /// `frameworkUpdates`; WEB puts them in the player bar's `markersMap`
    /// (and may carry the entity too). Either one is enough.
    static func parseChapters(_ json: [String: Any]) -> [VideoChapter] {
        let fromEntity = chaptersFromMarkersEntity(json)
        let chapters = fromEntity.isEmpty
            ? chaptersFromMarkersMap(json)
            : fromEntity
        // A single "chapter" is just the video; YouTube shows none then.
        return chapters.count > 1 ? chapters : []
    }

    private static func chaptersFromMarkersEntity(
        _ json: [String: Any]
    ) -> [VideoChapter] {
        let mutations = json.digArray(
            "frameworkUpdates", "entityBatchUpdate", "mutations"
        ) ?? []
        for mutation in mutations {
            guard let list = mutation.digDict(
                "payload", "macroMarkersListEntity", "markersList"
            ), list["markerType"] as? String == "MARKER_TYPE_CHAPTERS",
                let markers = list["markers"] as? [[String: Any]] else {
                continue
            }
            return sortedChapters(markers.compactMap { marker in
                guard let title = simpleText(from: marker["title"]),
                      let millis = millisValue(marker["startMillis"]) else {
                    return nil
                }
                return VideoChapter(title: title, start: millis / 1_000)
            })
        }
        return []
    }

    private static func chaptersFromMarkersMap(
        _ json: [String: Any]
    ) -> [VideoChapter] {
        let entries = json.digArray(
            "playerOverlays",
            "playerOverlayRenderer",
            "decoratedPlayerBarRenderer",
            "decoratedPlayerBarRenderer",
            "playerBar",
            "multiMarkersPlayerBarRenderer",
            "markersMap"
        ) ?? []
        let chapterKeys: Set = ["DESCRIPTION_CHAPTERS", "AUTO_CHAPTERS"]
        for entry in entries {
            guard let key = entry["key"] as? String, chapterKeys.contains(key),
                  let items = entry.digArray("value", "chapters") else {
                continue
            }
            return sortedChapters(items.compactMap { item in
                guard let renderer = item["chapterRenderer"] as? [String: Any],
                      let title = simpleText(from: renderer["title"]),
                      let millis = millisValue(
                          renderer["timeRangeStartMillis"]
                      ) else {
                    return nil
                }
                return VideoChapter(title: title, start: millis / 1_000)
            })
        }
        return []
    }

    /// Millisecond fields arrive as numbers on WEB and as strings on TV.
    private static func millisValue(_ value: Any?) -> Double? {
        if let number = value as? Double {
            return number
        }
        return (value as? String).flatMap(Double.init)
    }

    private static func sortedChapters(
        _ chapters: [VideoChapter]
    ) -> [VideoChapter] {
        chapters.sorted { $0.start < $1.start }
    }
}
