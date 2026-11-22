import UIKit

// MARK: - UICollectionViewDataSource

extension WatchViewController: UICollectionViewDataSource {
    private func configureChannelNavigation(
        for cell: VideoCell,
        video: Video
    ) {
        cell.onChannelTap = { [weak self] in
            guard let self,
                  let channelId = video.channelId
            else {
                return
            }
            videoRouter.openChannel(id: channelId, name: video.channelName)
        }
        cell.onMenuTap = { [weak self] anchor in
            guard let self else {
                return
            }
            VideoActionMenu.present(video: video, from: self, anchor: anchor)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    )
        -> Int {
        // Placeholders while the page loads: an empty list would let the
        // sidebar lay out at no height and come back scrolled.
        isLoadingRelated
            ? WatchPaging.relatedBatch
            : visibleRelatedVideos.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    )
        -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: VideoCell.reuseId,
            for: indexPath
        ) as? VideoCell else {
            return UICollectionViewCell()
        }
        guard let video = relatedVideo(at: indexPath) else {
            cell.configureSkeleton()
            return cell
        }
        let isLandscape =
            view.bounds.width > view.bounds.height
        cell.forceGridLayout = !isLandscape
        cell.configure(with: video)
        configureChannelNavigation(for: cell, video: video)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    )
        -> UICollectionReusableView {
        guard kind == UICollectionView
            .elementKindSectionHeader
        else {
            return UICollectionReusableView()
        }
        let header = collectionView
            .dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier:
                PlaylistSectionHeaderView.reuseIdentifier,
                for: indexPath
            ) as? PlaylistSectionHeaderView
            ?? PlaylistSectionHeaderView()
        let title: String = if watchPage?.servedOffline ?? false {
            "player.related.downloaded".localized
        } else {
            "player.related.title".localized
        }
        header.configure(
            title: title,
            color: ThemeManager.shared.primaryText
        )
        return header
    }
}

// MARK: - UICollectionViewDelegate

extension WatchViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        shouldSelectItemAt indexPath: IndexPath
    )
        -> Bool {
        !isOuterScrollViewDragging
            && !scrollView.isDecelerating
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        guard let video = relatedVideo(at: indexPath) else {
            return
        }
        requestAutoFullscreenIfEnabled(for: video)
        navigateTo(video)
    }
}

extension WatchViewController {
    /// Related only — the queue lives in its own panel now
    /// (`WatchViewController+Queue`). Shared with prefetching.
    func relatedVideo(at indexPath: IndexPath) -> Video? {
        visibleRelatedVideos[safe: indexPath.item]
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension WatchViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    )
        -> CGSize {
        CGSize(
            width: collectionView.bounds.width,
            height: WatchViewController.relatedHeaderHeight
        )
    }
}

// MARK: - UIScrollViewDelegate

extension WatchViewController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(
        _ scrollView: UIScrollView
    ) {
        guard scrollView === self.scrollView else {
            return
        }
        isOuterScrollViewDragging = true
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard scrollView === self.scrollView else {
            return
        }
        if !decelerate {
            isOuterScrollViewDragging = false
        }
    }

    func scrollViewDidEndDecelerating(
        _ scrollView: UIScrollView
    ) {
        guard scrollView === self.scrollView else {
            return
        }
        isOuterScrollViewDragging = false
    }

    /// The sidebar gets its content while it still has no size, and when the
    /// frame grows from zero UIKit hands the collection a proportional offset
    /// — 384 pt into 98 pt of content. Any offset past the end is nonsense
    /// nobody asked for, so it goes back to where it can legally sit.
    private func clampRelatedOffset(_ scrollView: UIScrollView) {
        guard !scrollView.isDragging, !scrollView.isDecelerating else {
            return
        }
        let maxY = max(
            0, scrollView.contentSize.height - scrollView.bounds.height
        )
        guard scrollView.contentOffset.y > maxY else {
            return
        }
        scrollView.contentOffset.y = maxY
    }

    /// Whichever view is carrying the related list: the page scroll in
    /// portrait, the sidebar's own collection in landscape. Only the first
    /// was ever asked, so a landscape sidebar stopped at the first batch.
    func scrollViewDidScroll(
        _ scrollView: UIScrollView
    ) {
        if scrollView === relatedCollectionView {
            clampRelatedOffset(scrollView)
        }
        guard scrollView === self.scrollView
            || scrollView === relatedCollectionView
        else {
            return
        }
        let threshold: CGFloat = 400
        let offset = scrollView.contentOffset.y
            + scrollView.bounds.height
        let contentHeight = scrollView.contentSize.height
        guard contentHeight > 0,
              offset >= contentHeight - threshold
        else {
            return
        }
        expandRelatedIfNeeded()
    }
}

// MARK: - PlaybackContext

extension WatchViewController: PlaybackContext {
    func updateStatusLabel(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            playerStatusLabel.text = text
            playerStatusLabel.isHidden = false
            playerSpinner.startAnimating()
        }
    }

    func setCaptionTracks(_ tracks: [SubtitleTrack]) {
        captionTracks = tracks
        videoPlayerView?.setCaptionTracks(
            tracks,
            activeLanguage: activeSubtitleLanguage
        )
        videoPlayerView?.onCCTapped = { [weak self] in
            self?.showSubtitlePicker()
        }
    }
}

// MARK: - Safe Collection Subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
