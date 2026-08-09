import UIKit

// MARK: - UICollectionViewDataSourcePrefetching

/// The related list had no prefetching at all, so its thumbnails only
/// started loading once a cell was already on screen.
extension WatchViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let pixelSize = ThumbnailSizing.pixelSize(
            for: collectionView
        )
        for url in thumbnailURLs(at: indexPaths) {
            ThumbnailImageView.prefetch(
                url: url,
                maxPixelSize: pixelSize
            )
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        let pixelSize = ThumbnailSizing.pixelSize(
            for: collectionView
        )
        for url in thumbnailURLs(at: indexPaths) {
            ThumbnailImageView.cancelPrefetch(
                url: url,
                maxPixelSize: pixelSize
            )
        }
    }

    private func thumbnailURLs(at indexPaths: [IndexPath]) -> [URL] {
        indexPaths.compactMap {
            guard let video = relatedVideo(at: $0) else {
                return nil
            }
            return URL(string: video.thumbnailURL)
        }
    }
}
