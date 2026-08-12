import UIKit

// MARK: - UICollectionViewDelegateFlowLayout

extension VideosViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard !isLoadingInitial else {
            return
        }
        openVideo(video(at: indexPath))
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard !isLoadingInitial,
              !isLoadingMore,
              currentContinuation != nil,
              nearFeedEnd(indexPath)
        else {
            return
        }
        isLoadingMore = true
        handleLoadMore()
    }

    private func nearFeedEnd(_ indexPath: IndexPath) -> Bool {
        useRails
            ? indexPath.section >= sections.count - 3
            : videosRemaining(after: indexPath) < 4
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let flow = collectionViewLayout
            as? UICollectionViewFlowLayout
        guard useRails, !isLoadingInitial else {
            return flow?.itemSize ?? .zero
        }
        // Full width minus the section's horizontal insets.
        let width = collectionView.bounds.width - 16
        return CGSize(
            width: width,
            height: ShelfRailCell.railHeight(forWidth: width)
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        guard !isLoadingInitial,
              section < sections.count,
              sections[section].title != nil
        else {
            return .zero
        }
        return CGSize(
            width: collectionView.bounds.width,
            height: VideoSectionHeaderView.height
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        insetForSectionAt section: Int
    ) -> UIEdgeInsets {
        // The default per-section inset would double the vertical gap
        // between stacked sections — only the first keeps a top inset.
        UIEdgeInsets(
            top: section == 0 ? 12 : 0,
            left: 8,
            bottom: 12,
            right: 8
        )
    }

    func scrollViewDidScroll(
        _ scrollView: UIScrollView
    ) {
        guard scrollView === collectionView else {
            return
        }
        topBarHider.handleScroll(scrollView)
        handleScroll(scrollView)
    }
}
