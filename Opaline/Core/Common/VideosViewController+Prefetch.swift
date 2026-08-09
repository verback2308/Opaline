import UIKit

extension VideosViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        guard !isLoadingInitial else {
            return
        }
        let pixelSize = ThumbnailSizing.pixelSize(
            for: collectionView
        )
        for indexPath in indexPaths {
            guard indexPath.section < sections.count,
                  indexPath.item < sections[indexPath.section].videos.count
            else {
                continue
            }
            let video = video(at: indexPath)
            if let url = URL(string: video.thumbnailURL) {
                ThumbnailImageView.prefetch(
                    url: url,
                    videoId: video.isShort ? nil : video.id,
                    maxPixelSize: pixelSize
                )
            }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        let pixelSize = ThumbnailSizing.pixelSize(
            for: collectionView
        )
        for indexPath in indexPaths {
            guard indexPath.section < sections.count,
                  indexPath.item < sections[indexPath.section].videos.count
            else {
                continue
            }
            let video = video(at: indexPath)
            if let url = URL(string: video.thumbnailURL) {
                ThumbnailImageView.cancelPrefetch(
                    url: url,
                    videoId: video.isShort ? nil : video.id,
                    maxPixelSize: pixelSize
                )
            }
        }
    }
}
