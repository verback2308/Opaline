import UIKit

class ThumbnailImageView: UIImageView {
    private var currentURL: URL?
    private var currentVideoId: String?
    private var loadToken: CancellationToken?
    private var fallbackImage: UIImage?
    private var isShowingFallback = false
    private var currentPixelSize = 0
    private var hasFailed = false

    /// Zero derives the decode target from the displayed thumbnail width.
    /// Set an explicit value for small fixed assets such as avatars.
    var maxPixelSize: Int = 0 {
        didSet {
            guard oldValue != maxPixelSize else {
                return
            }
            startLoadingIfNeeded()
        }
    }

    private var effectivePixelSize: Int {
        if maxPixelSize > 0 {
            return min(maxPixelSize, ThumbnailSizing.maximumPixelSize)
        }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        return ThumbnailSizing.pixelSize(
            forDisplayWidth: bounds.width,
            scale: scale
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ThemeManager.shared.thumbnailPlaceholder
        contentMode = .scaleAspectFill
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        startLoadingIfNeeded()
    }

    func setImage(
        url: URL,
        videoId: String? = nil,
        fallback: UIImage? = nil
    ) {
        fallbackImage = fallback
        // Deliberately keyed on content, not just the URL: callers clear
        // `image` and then re-set the same URL to force a reload (see
        // `ChannelAvatarView.configure`). Skipping on a URL match alone left
        // those views permanently blank.
        let hasContent = (image != nil && !isShowingFallback)
            || loadToken != nil
        if currentURL == url,
           currentVideoId == videoId,
           hasContent {
            return
        }
        loadToken?.cancel()
        loadToken = nil
        currentURL = url
        currentVideoId = videoId
        hasFailed = false
        if let fallback {
            image = fallback
            isShowingFallback = true
        }
        currentPixelSize = 0
        startLoadingIfNeeded()
    }

    private func startLoadingIfNeeded() {
        guard let url = currentURL else {
            return
        }
        guard maxPixelSize > 0 || bounds.width > 0 else {
            return
        }
        let target = effectivePixelSize
        guard shouldStartLoading(target: target) else {
            return
        }
        loadToken?.cancel()
        currentPixelSize = target
        loadToken = ThumbnailLoader.shared.load(
            url: url,
            maxPixelSize: target,
            videoId: currentVideoId
        ) { [weak self] result in
            self?.handleLoadResult(
                result,
                url: url,
                target: target
            )
        }
    }

    private func shouldStartLoading(target: Int) -> Bool {
        target > 0
            && !hasFailed
            && (currentPixelSize != target
                || (loadToken == nil && image == nil))
    }

    private func handleLoadResult(
        _ result: Result<ThumbnailLoadResult, Error>,
        url: URL,
        target: Int
    ) {
        guard currentURL == url,
              currentPixelSize == target
        else {
            return
        }
        loadToken = nil
        guard case .success(let loaded) = result else {
            hasFailed = true
            return
        }
        image = loaded.image
        isShowingFallback = false
    }

    func cancel() {
        loadToken?.cancel()
        loadToken = nil
        currentURL = nil
        currentVideoId = nil
        fallbackImage = nil
        isShowingFallback = false
        currentPixelSize = 0
        hasFailed = false
        image = nil
    }

    /// Shows the avatar at `url`, using a monogram rendered from
    /// `name` while loading, on failure, and when `url` is nil.
    func setAvatar(url: URL?, name: String) {
        let monogram = MonogramAvatar.image(for: name)
        guard let url else {
            cancel()
            image = monogram
            isShowingFallback = true
            return
        }
        setImage(url: url, fallback: monogram)
    }
}
