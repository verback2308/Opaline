import UIKit

extension WatchViewController {
    static let relatedHeaderHeight: CGFloat = 32

    /// One column everywhere except an iPad in portrait, which has the width
    /// for two: the landscape sidebar is narrow, and on iPhone the related list
    /// matches the single-column feeds on Home and Subscriptions.
    func relatedColumns(isLandscape: Bool) -> CGFloat {
        if isLandscape || UIDevice.current.userInterfaceIdiom != .pad {
            return 1
        }
        return 2
    }

    func updateLayoutForSize(_ size: CGSize? = nil) {
        // While in fullscreen the player view lives in the window, not in our
        // view hierarchy — skip layout until the user exits fullscreen.
        guard fullscreenSnapshot == nil else {
            return
        }
        layOutPage(for: size ?? view.bounds.size)
    }

    /// The page under the player, laid out for `resolved`. Leaving
    /// fullscreen calls it directly, while the player still covers the page.
    func layOutPage(for resolved: CGSize) {
        let isLandscape = resolved.width > resolved.height

        // Deliberately unconditional. Gating this on "the size changed"
        // looks safe and is not: the rotation's completion pass re-runs it
        // at the same size precisely to catch the collection view's bounds
        // once they have settled (see `computeItemSize`). Skipping it left
        // the related container sized from the pre-rotation width, i.e. a
        // half-screen gap under the comments.
        reconfigureLayout(isLandscape: isLandscape, resolved: resolved)

        // These are cheap and must run on every pass.
        relatedCollectionView.backgroundColor = ThemeManager.shared.background
        if !isLandscape {
            relatedCollectionView.alpha = 1
        }
        view.bringSubviewToFront(playerContainer)
        view.bringSubviewToFront(sidebarContainer)
        // The portrait panel can overlap the player at its expanded detent —
        // a no-op if it's currently attached to `sidebarContainer` instead
        // (landscape) or not attached at all (collapsed).
        if let sheet = sheetView {
            view.bringSubviewToFront(sheet)
        }
        view.bringSubviewToFront(queueBar)
    }

    /// The size-dependent half of `updateLayoutForSize`, split out only to
    /// keep that function within the body-length limit.
    private func reconfigureLayout(isLandscape: Bool, resolved: CGSize) {
        if isLandscape {
            activateLandscapeLayout()
        } else {
            activatePortraitLayout()
        }
        if let sv = relatedCollectionView.superview {
            sv.setNeedsLayout()
            sv.layoutIfNeeded()
        }
        if relatedCollectionView.bounds.width > 0 {
            updateRelatedLayout(isLandscape: isLandscape, containerSize: resolved)
        }
        layoutSheet(isLandscape: isLandscape)
        // Swap last: applying a layout that still carries the item size from
        // the previous width makes the flow layout complain.
        let expected = isLandscape ? landscapeRelatedLayout : portraitRelatedLayout
        if relatedCollectionView.collectionViewLayout !== expected {
            relatedCollectionView.setCollectionViewLayout(expected, animated: false)
        }
    }

    /// Moves the queue strip between spanning the page and spanning the
    /// sidebar.
    private func activateQueueBarSlot(isLandscape: Bool) {
        guard queueBarSlot.isLandscape != isLandscape else {
            return
        }
        queueBarSlot.isLandscape = isLandscape
        let (on, off) = isLandscape
            ? (queueBarSlot.landscape, queueBarSlot.portrait)
            : (queueBarSlot.portrait, queueBarSlot.landscape)
        NSLayoutConstraint.deactivate(off)
        NSLayoutConstraint.activate(on)
        updateQueueBar()
    }

    func activateLandscapeLayout() {
        activateQueueBarSlot(isLandscape: true)
        scrollTrailingConstraint?.isActive = false
        scrollToSidebarConstraint?.isActive = true
        sidebarTopConstraint?.isActive = true
        sidebarTrailingConstraint?.isActive = true
        sidebarBottomConstraint?.isActive = true
        sidebarWidthConstraint?.isActive = true
        sidebarContainer.isHidden = false
        playerTrailingConstraint?.isActive = false
        playerToSidebarConstraint?.isActive = true
        moveRelatedCollection(toLandscape: true)
        bottomCommentsConstraint?.isActive = true
    }

    func activatePortraitLayout() {
        activateQueueBarSlot(isLandscape: false)
        bottomCommentsConstraint?.isActive = false
        scrollToSidebarConstraint?.isActive = false
        scrollTrailingConstraint?.isActive = true
        sidebarTopConstraint?.isActive = false
        sidebarTrailingConstraint?.isActive = false
        sidebarBottomConstraint?.isActive = false
        sidebarWidthConstraint?.isActive = false
        sidebarContainer.isHidden = true
        playerToSidebarConstraint?.isActive = false
        playerTrailingConstraint?.isActive = true
        moveRelatedCollection(toLandscape: false)
        // Force multi-line labels to re-wrap at the new (wider) portrait width.
        metaLabel.invalidateIntrinsicContentSize()
        metaLabel.setNeedsLayout()
    }

    func updateRelatedLayout(
        isLandscape: Bool,
        containerSize: CGSize? = nil
    ) {
        let layout = isLandscape
            ? landscapeRelatedLayout
            : portraitRelatedLayout
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = isLandscape ? 0 : 6
        layout.sectionInset = UIEdgeInsets(
            top: 0, left: 8, bottom: 12, right: 8
        )
        let size = computeItemSize(
            layout: layout,
            isLandscape: isLandscape,
            containerSize: containerSize
        )
        if layout.itemSize != size {
            layout.itemSize = size
        }
        updateRelatedHeight(
            layout: layout,
            isLandscape: isLandscape,
            itemHeight: size.height
        )
        layout.invalidateLayout()
    }

    func computeItemSize(
        layout: UICollectionViewFlowLayout,
        isLandscape: Bool,
        containerSize: CGSize?
    )
        -> CGSize {
        let cols = relatedColumns(isLandscape: isLandscape)
        let inset = layout.sectionInset.left
            + layout.sectionInset.right
        let spacing = layout.minimumInteritemSpacing
            * (cols - 1)
        let baseWidth: CGFloat = if let containerSize {
            isLandscape
                ? (sidebarWidthConstraint?.constant ?? 0)
                : containerSize.width
        } else {
            relatedCollectionView.bounds.width
        }
        // The collection view can still be at its pre-transition width — iOS
        // also resizes the app off-screen for the multitasking snapshot — and
        // items wider than it make the flow layout complain. The transition's
        // completion pass re-runs this against the settled bounds.
        let actual = relatedCollectionView.bounds.width
        let width = actual > 0 ? min(baseWidth, actual) : baseWidth
        let available = max(width - inset - spacing, 120)
        let itemWidth = floor(available / cols)
        let itemHeight = itemWidth * (9.0 / 16.0) + 92
        return CGSize(width: itemWidth, height: itemHeight)
    }

    func updateRelatedHeight(
        layout: UICollectionViewFlowLayout,
        isLandscape: Bool,
        itemHeight: CGFloat
    ) {
        let cols = relatedColumns(isLandscape: isLandscape)
        let si = layout.sectionInset
        let relatedCount = CGFloat(
            visibleRelatedVideos.count
        )
        func sectionHeight(_ count: CGFloat) -> CGFloat {
            let rows = count == 0 ? 0 : ceil(count / cols)
            return rows == 0 ? 0 : si.top + si.bottom
                + rows * itemHeight
                + max(0, rows - 1)
                * layout.minimumLineSpacing
        }
        let total = sectionHeight(relatedCount)
            + WatchViewController.relatedHeaderHeight
        // Portrait: related is always full height — the comments panel is a
        // floating overlay above it now, not a slot swap (see
        // `WatchViewController+CommentsPanel`). Landscape still swaps: the
        // panel and related share the sidebar slot there.
        let desired = (isLandscape && isSheetExpanded) ? 0 : total
        if relatedSlot.height?.constant != desired {
            relatedSlot.height?.constant = desired
        }
    }

    func moveRelatedCollection(toLandscape isLandscape: Bool) {
        guard relatedSlot.isLandscape != isLandscape else {
            return
        }
        let old = isLandscape
            ? relatedSlot.portrait
            : relatedSlot.landscape
        NSLayoutConstraint.deactivate(old)
        relatedCollectionView.removeFromSuperview()
        if isLandscape {
            moveLandscapeRelated()
        } else {
            relatedCollectionView.isScrollEnabled = false
            contentView.addSubview(relatedCollectionView)
            NSLayoutConstraint.activate(relatedSlot.portrait)
        }
        relatedSlot.isLandscape = isLandscape
        // `VideoCell` picks its layout from `forceGridLayout`, which is only
        // set in `cellForItemAt`. Rotating changes the item size and relays
        // the existing cells out, but never re-configures them, so cells
        // built in landscape keep the horizontal arrangement inside a
        // portrait grid box. Reloading re-runs the configuration; it costs
        // one pass over the visible cells and only happens on rotation.
        relatedCollectionView.reloadData()
    }

    private func moveLandscapeRelated() {
        relatedCollectionView.isScrollEnabled = true
        // Reset any scroll offset carried over from portrait so the first video is
        // fully visible at the top of the sidebar when entering landscape.
        relatedCollectionView.setContentOffset(.zero, animated: false)
        sidebarContainer.addSubview(relatedCollectionView)
        let rv = relatedCollectionView
        let sc = sidebarContainer
        relatedSlot.landscape = [
            rv.topAnchor.constraint(equalTo: sc.topAnchor),
            rv.leadingAnchor.constraint(equalTo: sc.leadingAnchor),
            rv.trailingAnchor.constraint(equalTo: sc.trailingAnchor),
            rv.bottomAnchor.constraint(equalTo: sc.bottomAnchor)
        ]
        NSLayoutConstraint.activate(relatedSlot.landscape)
    }
}

// MARK: - Rotation

extension WatchViewController {
    override func viewWillTransition(
        to size: CGSize,
        with coordinator:
        UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(
            to: size,
            with: coordinator
        )
        coordinator.animate(
            alongsideTransition: { [weak self] _ in
                guard let self else {
                    return
                }
                // On iPhone landscape *is* fullscreen: the rotation itself
                // drives entering and leaving it.
                syncFullscreenWithRotation(isLandscape: size.width > size.height)
                // While in fullscreen the player view lives directly in the
                // window; keep its frame in sync with the rotating window.
                if fullscreenSnapshot != nil,
                   let window = view.window {
                    videoPlayerView?.frame = window.bounds
                    videoPlayerView?.setNeedsLayout()
                } else {
                    updateLayoutForSize(size)
                }
                view.layoutIfNeeded()
            },
            completion: { [weak self] _ in
                self?.updateLayoutForSize()
            }
        )
    }
}
