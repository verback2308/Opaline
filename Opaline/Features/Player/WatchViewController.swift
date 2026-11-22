import AVKit
import UIKit

private func makePortraitRelatedLayout() -> UICollectionViewFlowLayout {
    let layout = UICollectionViewFlowLayout()
    layout.minimumLineSpacing = 12
    layout.minimumInteritemSpacing = 8
    layout.sectionInset = UIEdgeInsets(
        top: 0,
        left: 12,
        bottom: 16,
        right: 12
    )
    return layout
}

private func makeLandscapeRelatedLayout() -> UICollectionViewFlowLayout {
    let layout = UICollectionViewFlowLayout()
    layout.minimumLineSpacing = 12
    layout.minimumInteritemSpacing = 0
    layout.sectionInset = UIEdgeInsets(
        top: 0,
        left: 8,
        bottom: 12,
        right: 8
    )
    return layout
}

final class WatchViewController: UIViewController {
    // MARK: - Dependencies

    var initialVideo: Video
    let client: WatchService
    let engagementClient: EngagementService
    let playlistClient: PlaylistService
    let channelInfoStore: ChannelInfoStore
    let videoRouter: VideoRouter
    let cache = AppCache.shared

    // MARK: - State

    var videoHistory: [Video] = []
    var watchPage: WatchPage?
    var isSubscribed: Bool = false
    var allRelatedVideos: [Video] = []
    var visibleRelatedVideos: [Video] = []
    /// Top-level comments plus their loaded replies; `commentRows` is the
    /// flattened view of it that the table actually reads (rebuilt in
    /// `renderComments`, never recomputed per row).
    /// `commentHeightCache` holds measured row heights keyed by comment, so
    /// self-sizing rows scrolling back in don't shift the content offset.
    var commentThreads: [CommentThread] = [], commentRows: [CommentRow] = []
    var commentHeightCache: [String: CGFloat] = [:], commentSortOptions: [CommentSortOption] = []
    /// `commentsPreview` is pinned, so re-sorting doesn't swap the row.
    var commentsContinuation: String?, commentsPreview: Comment?
    var playlistOptions: [PlaylistAddOption]?
    /// What the sliding panel is showing, or nil when it is closed. Set as
    /// the panel is presented and cleared as it starts to leave, so the
    /// dismiss animation still runs against the view `sheetView` holds.
    var presentedSheet: PlayerSheetKind?
    var videoPlayerView: VideoPlayerView?
    /// Retains the active resource loader (AVURLAsset holds its delegate weakly),
    /// e.g. a source's HLS proxy.
    var activeResourceLoader: AVAssetResourceLoaderDelegate?
    var statusObservation: NSKeyValueObservation?
    var descriptionExpanded = false
    /// Raw (un-linkified) description text, kept so the attributed text can
    /// be rebuilt when the theme changes.
    var descriptionText = ""
    /// `hasLoadedComments` separates "nothing yet" from "nothing at
    /// all": a load is always coming when the screen opens, so the
    /// empty message must not flash before the first result lands.
    var isLoadingComments = false, hasLoadedComments = false
    /// The watch page is applied twice (cache, then network) but its
    /// one-shot side effects — RYD/SponsorBlock, playlist prefetch,
    /// comments — must start only once per video. Set to the videoId whose
    /// side effects already started; nil once the controller moves on.
    var sideEffectsStartedForVideoId: String?
    /// Cached result of the last `applyDescriptionText()` run, keyed by the
    /// inputs that affect it, so an unrelated re-apply (e.g. the watch page
    /// landing twice) doesn't re-run the linkify pass.
    var descriptionAttributedCache: DescriptionAttributedCache?
    let sponsorBlock = SponsorBlockController()
    var autoplayOverlay: AutoplayOverlayView?
    let playbackFacade = PlaybackFacade()
    var pageLoadToken = CancellationToken()
    var isOuterScrollViewDragging = false, didSeekToSavedPosition = false
    var isLoadingQueuePage = false
    /// Source-reported: duration, and where the stream itself starts.
    var preparedDuration: Double?, itemStartsAt: Double?
    var captionTracks: [SubtitleTrack] = [], activeSubtitleLanguage: String?
    var backgroundEnteredAt: Date?, savedPlayerForBackground: AVPlayer?
    var isRecoveringPlayback = false, hasSeenPlaybackError = false
    /// Frozen during a recovery seek: a fresh item's zeroed clock must not
    /// overwrite where the user actually was.
    var lastPlaybackPosition = 0.0, pendingRecoverySeek = false, pendingResumeSeek: CMTime?
    let queue = PlaybackQueue.shared

    // MARK: - UI Elements

    let scrollView = UIScrollView()
    let contentView = UIView()
    let relatedCollectionView: UICollectionView
    let sidebarContainer = UIView()
    let portraitRelatedLayout: UICollectionViewFlowLayout
    let landscapeRelatedLayout: UICollectionViewFlowLayout
    let playerContainer = UIView()
    let playerSpinner = UIActivityIndicatorView(
        style: .whiteLarge
    )
    let playerStatusLabel = UILabel()
    var statsOverlay: StatsOverlayView?
    let titleLabel = UILabel()
    let metaLabel = UILabel()
    let channelAvatarView = ThumbnailImageView(
        frame: .zero
    )
    let channelNameLabel = UILabel()
    let channelMetaLabel = UILabel()
    let subscribeButton = UIButton(type: .system)
    let descriptionLabel = UITextView()
    let descriptionButton = UIButton(type: .system)
    let commentsLabel = UILabel()
    let commentsHeaderStack = UIStackView()
    /// Collapsed state: holds at most one row (skeleton, empty message, or
    /// the single preview comment) — never the full list. Also the card
    /// itself: `applyTheme` gives it a distinct background.
    /// The preview row, plus the plain view that draws the card behind it —
    /// a stack view ignores `backgroundColor` before iOS 14.
    let commentsStackView = UIStackView(), commentsPreviewCard = UIView()
    let commentsTableView = UITableView(
        frame: .zero, style: .plain
    )
    /// The one instance that ever backs the collapsed preview row.
    let commentPreviewContentView = CommentContentView()
    /// Expanded-panel chrome — see `WatchViewController+Sheet`.
    lazy var commentsPanel = PlayerSheetView(list: commentsTableView)
    var loadedQueuePanel: QueuePanelController?
    /// Bottom strip naming the queue while one is playing — see
    /// `WatchViewController+Queue`.
    let queueBar = QueueBarView()
    /// The panel on screen right now, of the two.
    var sheetView: PlayerSheetView?
    let actionBar = UIStackView()
    let likeButton = UIButton(type: .system)
    let dislikeButton = UIButton(type: .system)
    let shareButton = UIButton(type: .system)
    let saveButton = UIButton(type: .system)
    let downloadButton = UIButton(type: .system)
    /// Doubles as the download button's caption: "Download" at rest, the
    /// running percentage while a job is on.
    let downloadStatusLabel = UILabel()
    let likeCountLabel = UILabel()
    let dislikeCountLabel = UILabel()
    var likeCount: String?, dislikeCount: String?
    var currentLikeStatus: LikeStatus = .indifferent

    // MARK: - Constraints

    var playerAspectConstraint: NSLayoutConstraint?
    var relatedSlot = SlotLayout(), queueBarSlot = SlotLayout()
    /// Portrait panel's draggable top edge, in `view` coordinates. `.landscape`/
    /// `.isLandscape` on the slot double as the sidebar bookkeeping when it isn't.
    var sheetTopConstraint: NSLayoutConstraint?, sheetSlot = SlotLayout()
    /// True mid-pan (layout passes must not fight the user's finger); true
    /// when resting at the full-screen detent rather than below the player.
    /// Set while a drag or a presentation owns the panel's offset, so the
    /// layout pass leaves it alone instead of snapping it to a detent.
    var isSheetOffsetPinned = false, isSheetDetentExpanded = false
    var playerTopConstraint: NSLayoutConstraint?
    var playerLeadingConstraint: NSLayoutConstraint?
    var playerTrailingConstraint: NSLayoutConstraint?
    var playerToSidebarConstraint: NSLayoutConstraint?
    var scrollTopToPlayerConstraint: NSLayoutConstraint?
    var scrollTrailingConstraint: NSLayoutConstraint?
    var scrollToSidebarConstraint: NSLayoutConstraint?
    var sidebarTopConstraint: NSLayoutConstraint?
    var sidebarTrailingConstraint: NSLayoutConstraint?
    var sidebarBottomConstraint: NSLayoutConstraint?
    var sidebarWidthConstraint: NSLayoutConstraint?
    var bottomCommentsConstraint: NSLayoutConstraint?
    /// Related is a skeleton until the watch page answers.
    var isLoadingRelated = true
    var fullscreenSnapshot: FullscreenSnapshot?
    /// True from the moment the exit animation starts until the player is back
    /// in place — the status bar follows this, not the player's own state.
    /// `autoFullscreenVideoId`: see `requestAutoFullscreenIfEnabled(for:)`.
    var isLeavingFullscreen = false, autoFullscreenVideoId: String?
    var channelTopToMeta, channelTopToDesc: NSLayoutConstraint?
    /// Pins the interface while a fullscreen toggle rotates it against the way
    /// the device is physically held; cleared once the two agree again. `Held`
    /// marks the lock taken at open instead: it waits for the phone to be
    /// turned out of *that* hold, not for any particular orientation.
    var orientationLock: UIInterfaceOrientationMask?, orientationLockHeld: UIDeviceOrientation?

    // MARK: - Computed Properties

    override var shouldAutorotate: Bool {
        true
    }

    override var supportedInterfaceOrientations:
        UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return orientationLock ?? .allButUpsideDown
    }

    // MARK: - Initializers

    init(
        video: Video,
        watchService: WatchService,
        engagementService: EngagementService,
        playlistService: PlaylistService,
        channelInfoStore: ChannelInfoStore,
        videoRouter: VideoRouter = .shared
    ) {
        let portraitLayout = makePortraitRelatedLayout()
        portraitRelatedLayout = portraitLayout

        let landscapeLayout = makeLandscapeRelatedLayout()
        landscapeRelatedLayout = landscapeLayout

        relatedCollectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: portraitLayout
        )
        initialVideo = video
        client = watchService
        engagementClient = engagementService
        playlistClient = playlistService
        self.channelInfoStore = channelInfoStore
        self.videoRouter = videoRouter
        super.init(nibName: nil, bundle: nil)
        playbackFacade.context = self
        keepOpeningOrientation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The first video never passes through `loadVideoInternal`.
        applyResumePolicy(for: initialVideo)
        setupLayout()
        applyTheme()
        setupNavigationBar()
        loadInitialState()
        let id = initialVideo.id
        if let cached = cache.cachedWatchPage(
            videoId: id
        ) {
            applyWatchPage(cached)
        }
        loadWatchPage()
        addNotificationObservers()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutForSize()
        adjustForFloatingNavBar()
    }

    override func viewWillDisappear(
        _ animated: Bool
    ) {
        super.viewWillDisappear(animated)
        let isDismissing = isMovingFromParent
            || isBeingDismissed
            || navigationController?.isBeingDismissed == true
        if isDismissing {
            pageLoadToken.cancel()
            videoPlayerView?.player?.pause()
        }
    }

    // MARK: - Deinitializer

    deinit {
        NotificationCenter.default
            .removeObserver(self)
        statusObservation?.invalidate()
        statusObservation = nil
        if let item =
            videoPlayerView?.player?.currentItem {
            stopObservingPlayerItem(item)
        }
        videoPlayerView?.detach()
        playbackFacade.reset()
    }
}
