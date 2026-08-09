import UIKit

extension ThumbnailImageView {
    static var cachingEnabled: Bool {
        ThumbnailLoader.shared.cachingEnabled
    }

    static func clearCache() {
        AppLog.img("clear all")
        ThumbnailLoader.shared.clearCache()
    }

    static func invalidate(url: String) {
        guard let url = URL(string: url) else {
            return
        }
        ThumbnailLoader.shared.invalidate(url: url)
    }

    static func prefetch(
        url: URL,
        videoId: String? = nil,
        maxPixelSize: Int = ThumbnailSizing.defaultPixelSize
    ) {
        ThumbnailLoader.shared.prefetch(
            url: url,
            maxPixelSize: maxPixelSize,
            videoId: videoId
        )
    }

    static func cancelPrefetch(
        url: URL,
        videoId: String? = nil,
        maxPixelSize: Int = ThumbnailSizing.defaultPixelSize
    ) {
        ThumbnailLoader.shared.cancelPrefetch(
            url: url,
            maxPixelSize: maxPixelSize,
            videoId: videoId
        )
    }
}
