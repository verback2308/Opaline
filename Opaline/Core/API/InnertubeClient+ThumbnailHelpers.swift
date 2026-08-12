import Foundation

extension InnertubeClient {
    static func extractThumbnailURL(
        from value: Any?
    ) -> String? {
        if let dict = value as? [String: Any] {
            if let thumbs = dict["thumbnails"]
                as? [[String: Any]],
               let url = bestThumbnailURL(from: thumbs) {
                return url
            }
            // ViewModel-era image shape: image.sources[].url
            if let sources = dict["sources"]
                as? [[String: Any]],
               let url = sources.last?["url"] as? String,
               !url.isEmpty {
                return normalizeThumbnailURL(url)
            }
            for child in dict.values {
                if let url = extractThumbnailURL(
                    from: child
                ) {
                    return url
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let url = extractThumbnailURL(
                    from: child
                ) {
                    return url
                }
            }
        }
        return nil
    }

    static func normalizeThumbnailURL(
        _ url: String
    ) -> String {
        if url.hasPrefix("//") {
            return "https:\(url)"
        }
        return url
    }

    /// Picks the largest `thumbnails` entry by pixel area. `.last` is not
    /// reliably the highest resolution — home feed entries are often mqdefault
    /// (320×180) at the end while smaller sizes come first.
    static func bestThumbnailURL(
        from thumbs: [[String: Any]]
    ) -> String? {
        var bestURL: String?
        var bestPixels = 0
        for thumb in thumbs {
            guard let url = thumb["url"] as? String,
                  !url.isEmpty
            else {
                continue
            }
            let width = thumb["width"] as? Int ?? 0
            let height = thumb["height"] as? Int ?? 0
            let pixels = width * height
            if pixels > bestPixels {
                bestPixels = pixels
                bestURL = url
            }
        }
        if let bestURL {
            return normalizeThumbnailURL(bestURL)
        }
        if let url = thumbs.last?["url"] as? String,
           !url.isEmpty {
            return normalizeThumbnailURL(url)
        }
        return nil
    }

    static func preferredThumbnailURL(
        videoId: String,
        fallbackURL: String
    ) -> String {
        guard !videoId.isEmpty else {
            return normalizeThumbnailURL(fallbackURL)
        }
        return AppURLs.YouTube.thumbnailURL(videoId: videoId)
    }

    static func logThumbnailChoice(
        videoId: String,
        chosenURL: String,
        fallbackURL: String
    ) {
        _ = videoId
        _ = chosenURL
        _ = fallbackURL
    }

    static func thumbnailsLastURL(
        _ value: Any?
    ) -> String {
        guard let dict = value as? [String: Any],
              let thumbs = dict["thumbnails"]
                as? [[String: Any]],
              let url = bestThumbnailURL(from: thumbs)
        else {
            return ""
        }
        return url
    }

    static func collectThumbnailURLs(
        in value: Any
    ) -> Set<String> {
        var result = Set<String>()
        if let dict = value as? [String: Any] {
            if let thumbs = dict["thumbnails"]
                as? [[String: Any]] {
                for thumb in thumbs {
                    if let url = thumb["url"] as? String,
                       !url.isEmpty {
                        result.insert(url)
                    }
                }
            }
            for child in dict.values {
                result.formUnion(
                    collectThumbnailURLs(in: child)
                )
            }
        } else if let array = value as? [Any] {
            for child in array {
                result.formUnion(
                    collectThumbnailURLs(in: child)
                )
            }
        }
        return result
    }
}
