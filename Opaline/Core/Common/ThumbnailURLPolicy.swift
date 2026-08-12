import Foundation
import UIKit

enum ThumbnailSizing {
    static let defaultPixelSize = 640
    private static let decodeSteps = [320, 640, 960]
    static let maximumPixelSize = decodeSteps.last ?? defaultPixelSize

    static func pixelSize(
        forDisplayWidth width: CGFloat,
        scale: CGFloat
    ) -> Int {
        guard width > 0 else {
            return defaultPixelSize
        }
        let pixels = Int(ceil(width * max(scale, 1)))
        return decodeSteps.first { $0 >= pixels }
            ?? maximumPixelSize
    }

    static func pixelSize(
        for collectionView: UICollectionView
    ) -> Int {
        let flow = collectionView.collectionViewLayout
            as? UICollectionViewFlowLayout
        let width = flow?.itemSize.width ?? collectionView.bounds.width
        let scale = collectionView.window?.screen.scale
            ?? UIScreen.main.scale
        return pixelSize(forDisplayWidth: width, scale: scale)
    }
}

enum ThumbnailURLPolicy {
    private static let standardStems = [
        "maxresdefault",
        "sddefault",
        "hqdefault"
    ]

    static func candidates(
        for url: URL,
        videoId: String? = nil
    ) -> [URL] {
        if let videoId, !videoId.isEmpty {
            return canonicalCandidates(for: url, videoId: videoId)
        }
        guard isStandardYouTubeThumbnail(url) else {
            return [url]
        }
        let names: [String]
        let originalStem = url.deletingPathExtension()
            .lastPathComponent
        switch originalStem {
        case "maxresdefault":
            names = standardStems.map { "\($0).jpg" }
        case "sddefault":
            names = [
                "sddefault.jpg", "maxresdefault.jpg", "hqdefault.jpg"
            ]
        case "hqdefault", "mqdefault":
            names = [
                "maxresdefault.jpg", "sddefault.jpg", "hqdefault.jpg",
                url.lastPathComponent
            ]
        default:
            names = [url.lastPathComponent]
        }
        let generated = names.compactMap {
            replacingLastPathComponent(of: url, with: $0)
        }
        return unique(generated + [url])
    }

    private static func canonicalCandidates(
        for url: URL,
        videoId: String
    ) -> [URL] {
        let canonical = standardStems.compactMap {
            URL(string: "https://i.ytimg.com/vi/\(videoId)/\($0).jpg")
        }
        return unique(canonical + candidates(for: url, videoId: nil))
    }

    private static func isStandardYouTubeThumbnail(
        _ url: URL
    ) -> Bool {
        let parts = url.pathComponents
        let isVideoPath = parts.count >= 4
            && (parts[1] == "vi" || parts[1] == "vi_webp")
        guard url.host == "i.ytimg.com",
              isVideoPath
        else {
            return false
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return standardStems.contains(stem) || stem == "mqdefault"
    }

    private static func replacingLastPathComponent(
        of url: URL,
        with filename: String
    ) -> URL? {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        if url.query?.contains("sqp=") == true {
            components.query = nil
        }
        let parts = url.pathComponents
        if parts.count >= 3 {
            components.path = "/vi/\(parts[2])/\(filename)"
        } else {
            components.path = url.deletingLastPathComponent()
                .appendingPathComponent(filename).path
        }
        return components.url
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
}

struct ThumbnailRequest {
    let candidates: [URL]
    let maxPixelSize: Int

    var identity: String {
        "\(candidates.first?.absoluteString ?? "")#\(maxPixelSize)"
    }

    init(
        url: URL,
        maxPixelSize: Int,
        videoId: String? = nil
    ) {
        candidates = ThumbnailURLPolicy.candidates(
            for: url,
            videoId: videoId
        )
        self.maxPixelSize = min(
            max(maxPixelSize, 1),
            ThumbnailSizing.maximumPixelSize
        )
    }

    func cacheKey(for url: URL) -> String {
        "\(url.absoluteString)#\(maxPixelSize)"
    }
}
