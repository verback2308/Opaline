import ImageIO
import UIKit

extension ThumbnailLoader {
    func decode(
        data: Data,
        maxPixelSize: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            options as CFDictionary
        ) else {
            return nil
        }
        return makeThumbnail(
            from: source,
            maxPixelSize: maxPixelSize
        )
    }

    func decode(
        fileURL: URL,
        maxPixelSize: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            options as CFDictionary
        ) else {
            return nil
        }
        return makeThumbnail(
            from: source,
            maxPixelSize: maxPixelSize
        )
    }

    private func makeThumbnail(
        from source: CGImageSource,
        maxPixelSize: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
