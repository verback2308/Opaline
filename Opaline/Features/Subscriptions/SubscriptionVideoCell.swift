import UIKit

class SubscriptionVideoCell: UITableViewCell {
    static let reuseId = "SubscriptionVideoCell"

    let thumbnail = ThumbnailImageView(frame: .zero)
    let durationLabel = UILabel()
    let progressTrack = UIView()
    let progressFill = UIView()
    var watchFraction: CGFloat = 0
    let channelAvatarView = ThumbnailImageView(frame: .zero)
    let titleLabel = UILabel()
    let channelLabel = UILabel()
    let dateLabel = UILabel()
    private var representedChannelId: String?
    var onChannelTap: (() -> Void)?
    let menuButton = UIButton(type: .system)
    var onMenuTap: ((UIView) -> Void)?
    var cachedTitleHeight: CGFloat = 0
    var cachedTitleWidth: CGFloat = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyTheme),
            name: ThemeManager.didChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        selectionStyle = .none
        thumbnail.layer.cornerRadius = 0
        thumbnail.layer.masksToBounds = true
        contentView.addSubview(thumbnail)
        setupProgressBar()
        setupDurationLabel()
        setupChannelAvatar()
        setupLabels()
        setupTapGestures()
        applyTheme()
    }

    private func setupProgressBar() {
        progressTrack.backgroundColor = UIColor.black
            .withAlphaComponent(0.3)
        progressTrack.isHidden = true
        thumbnail.addSubview(progressTrack)
        progressFill.backgroundColor = UIColor(
            red: 1, green: 0, blue: 0, alpha: 1
        )
        thumbnail.addSubview(progressFill)
    }

    private func setupDurationLabel() {
        durationLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = ThemeManager.shared.durationBackground
        durationLabel.layer.cornerRadius = 3
        durationLabel.layer.masksToBounds = true
        durationLabel.textAlignment = .center
        thumbnail.addSubview(durationLabel)
    }

    private func setupChannelAvatar() {
        channelAvatarView.layer.cornerRadius = 18
        channelAvatarView.layer.masksToBounds = true
        channelAvatarView.isUserInteractionEnabled = true
        contentView.addSubview(channelAvatarView)
    }

    private func setupLabels() {
        titleLabel.numberOfLines = 2
        titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        contentView.addSubview(titleLabel)
        channelLabel.font = UIFont.systemFont(ofSize: 12)
        channelLabel.isUserInteractionEnabled = true
        contentView.addSubview(channelLabel)
        dateLabel.font = UIFont.systemFont(ofSize: 12)
        contentView.addSubview(dateLabel)
        menuButton.setImage(resizedNavBarIcon("icon_ellipsis_vertical", size: 16), for: .normal)
        menuButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        menuButton.addTarget(self, action: #selector(handleMenuTap), for: .touchUpInside)
        contentView.addSubview(menuButton)
    }

    private func setupTapGestures() {
        let avatarTap = UITapGestureRecognizer(target: self, action: #selector(handleChannelTap))
        channelAvatarView.addGestureRecognizer(avatarTap)
        let labelTap = UITapGestureRecognizer(target: self, action: #selector(handleChannelTap))
        channelLabel.addGestureRecognizer(labelTap)
    }

    @objc
    private func handleChannelTap() { onChannelTap?() }

    @objc
    private func handleMenuTap() { onMenuTap?(menuButton) }

    @objc
    private func applyTheme() {
        let theme = ThemeManager.shared
        backgroundColor = theme.background
        contentView.backgroundColor = theme.background
        titleLabel.textColor = theme.primaryText
        channelLabel.textColor = theme.secondaryText
        dateLabel.textColor = theme.secondaryText
        menuButton.tintColor = theme.secondaryText
    }

    func configureSkeleton() {
        hideSkeleton()
        titleLabel.text = nil
        channelLabel.text = nil
        dateLabel.text = nil
        thumbnail.image = nil
        channelAvatarView.image = nil
        durationLabel.isHidden = true
        menuButton.isHidden = true
        contentView.showSkeleton()
    }

    func configure(with video: Video) {
        applyTheme()
        menuButton.isHidden = false
        representedChannelId = video.channelId
        titleLabel.text = video.title
        channelLabel.text = video.channelName
        dateLabel.text = VideoCardHelper.metaText(
            viewCount: video.viewCount,
            publishedAt: video.publishedAt,
            separator: " · "
        )

        VideoCardHelper.loadChannelAvatar(for: video, into: channelAvatarView) { [weak self] in
            self?.representedChannelId == video.channelId
        }
        VideoCardHelper.configureBadges(
            video: video,
            durationLabel: durationLabel,
            liveBadgeView: nil
        )

        if let url = URL(string: video.thumbnailURL) {
            thumbnail.setImage(
                url: url,
                videoId: video.isShort ? nil : video.id
            )
        }
        applyWatchProgress(videoId: video.id)
        cachedTitleHeight = 0
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hideSkeleton()
        representedChannelId = nil
        thumbnail.cancel()
        channelAvatarView.cancel()
        titleLabel.text = nil
        channelLabel.text = nil
        dateLabel.text = nil
        durationLabel.isHidden = true
        channelAvatarView.isHidden = false
        watchFraction = 0
        progressTrack.isHidden = true
        progressFill.isHidden = true
        onChannelTap = nil
        onMenuTap = nil
        cachedTitleHeight = 0
    }

    func applyWatchProgress(videoId: String) {
        if let prog = WatchProgressStore.shared.progress(
            forVideoId: videoId
        ), prog.shouldShow {
            watchFraction = CGFloat(prog.fraction)
            progressTrack.isHidden = false
            progressFill.isHidden = false
        } else {
            watchFraction = 0
            progressTrack.isHidden = true
            progressFill.isHidden = true
        }
    }
}
