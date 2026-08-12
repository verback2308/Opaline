import UIKit

class VideosViewController: UIViewController, ScrollableToTop {
    // MARK: - Type Properties

    static let skeletonCount = 9

    // MARK: - Instance Properties

    var columns: Int { 5 }
    /// Lay the grid out with vertical Shorts cards instead of landscape
    /// video cells. Screens that show a Shorts tab flip this per tab.
    var usesShortsGrid: Bool { false }

    /// Whether pages' shelf partitions render as titled sections.
    /// Pages without shelf info look the same either way.
    var groupsByShelf: Bool { true }

    var useRails: Bool { false }

    /// Mutated only by the Page Management extension.
    var sections: [VideoSection] = []
    private(set) var collectionView: UICollectionView?
    let channelViewControllerFactory: (String, String) -> UIViewController
    let videoRouter: VideoRouter
    let spinner = UIActivityIndicatorView(style: .white)
    var isLoadingInitial = true
    var isLoadingMore = false
    /// Hides the navigation bar on scroll-down; subclasses with extra
    /// top bars (Home's chips) hook `onChange` to hide them in sync.
    lazy var topBarHider = TopBarAutoHider(owner: self)

    /// Backing state for page accumulation — mutated only by the
    /// Page Management extension (`VideosViewController+Pages`).
    var continuationToken: String?
    var seenVideoIds: Set<String> = []
    /// Sections with an in-flight horizontal (rail) page fetch.
    var loadingRailSections: Set<Int> = []

    var currentContinuation: String? { continuationToken }
    var videoCount: Int { sections.reduce(0) { $0 + $1.videos.count } }

    init(
        channelViewControllerFactory: @escaping (
            String,
            String
        ) -> UIViewController,
        videoRouter: VideoRouter = .shared
    ) {
        self.channelViewControllerFactory = channelViewControllerFactory
        self.videoRouter = videoRouter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View Life Cycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupSpinner()
        applyTheme()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyTheme),
            name: ThemeManager.didChangeNotification,
            object: nil
        )
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateItemSize()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // The hidden bar belongs to the shared navigation controller —
        // restore it before another screen takes over.
        topBarHider.showBars()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { [weak self] _ in
            self?.updateItemSize()
            self?.collectionView?
                .collectionViewLayout.invalidateLayout()
        }
    }

    // MARK: - Methods

    private func setupCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(
            top: 12, left: 8, bottom: 12, right: 8
        )

        let cv = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: layout
        )
        cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        registerViews(in: cv)
        cv.dataSource = self
        cv.delegate = self
        cv.prefetchDataSource = self

        let refresh = UIRefreshControl()
        refresh.addTarget(
            self,
            action: #selector(handleRefresh),
            for: .valueChanged
        )
        cv.refreshControl = refresh

        view.addSubview(cv)
        collectionView = cv
    }

    private func registerViews(in cv: UICollectionView) {
        cv.register(
            ShortThumbnailCell.self,
            forCellWithReuseIdentifier: ShortThumbnailCell.reuseIdentifier
        )
        cv.register(
            VideoCell.self,
            forCellWithReuseIdentifier: VideoCell.reuseId
        )
        cv.register(
            VideoSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: VideoSectionHeaderView.reuseId
        )
        cv.register(
            ShelfRailCell.self,
            forCellWithReuseIdentifier: ShelfRailCell.reuseId
        )
    }

    private func setupSpinner() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            spinner.centerYAnchor.constraint(
                equalTo: view.centerYAnchor
            )
        ])
        spinner.startAnimating()
    }

    @objc
    func handleRefresh() {}

    func handleScroll(_ scrollView: UIScrollView) {}

    @objc dynamic
    func scrollToTop() {
        topBarHider.showBars()
        collectionView?.setContentOffset(
            CGPoint(x: 0, y: -(collectionView?.adjustedContentInset.top ?? 0)),
            animated: true
        )
    }

    // Override in subclasses to load next page
    func handleLoadMore() {}

    /// Override in subclasses to fetch a rail's horizontal page.
    /// Must call `completion` (on the main thread) exactly once.
    func loadRailPage(
        token: String,
        completion: @escaping (FeedPage?) -> Void
    ) {
        completion(nil)
    }

    // Kept in the class body (not the extension) so subclasses can
    // override it.
    func openVideo(_ video: Video) {
        // A grid is a visible order — swiping continues down it rather than
        // through a shuffled pool, which is what a shelf gets.
        let following = sections
            .flatMap { $0.videos }
            .filter { $0.isShort }
            .drop { $0.id != video.id }
            .dropFirst()
        videoRouter.open(
            video: video,
            from: self,
            shorts: .list(Array(following))
        )
    }

    @objc
    func applyTheme() {
        let theme = ThemeManager.shared
        view.backgroundColor = theme.background
        collectionView?.backgroundColor = theme.background
    }
}
