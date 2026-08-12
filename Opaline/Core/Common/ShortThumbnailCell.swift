import UIKit

/// A vertical Shorts poster with its title and view count. Shared UI: the
/// subscriptions shelf and the channel's Shorts grid both show this 9:16
/// card, only the layout around it differs.
final class ShortThumbnailCell: UICollectionViewCell {
    static let reuseIdentifier = "ShortThumbnailCell"
    private static let titleFont = UIFont.systemFont(ofSize: 13, weight: .medium)
    private static let viewsFont = UIFont.systemFont(ofSize: 12)
    private static let posterGap: CGFloat = 6
    private static let labelGap: CGFloat = 4

    /// Height the title and view count add below the poster. Derived from
    /// the fonts, so the view count can't end up clipped again when one of
    /// them changes.
    static let captionHeight: CGFloat = ceil(
        posterGap + titleFont.lineHeight * 2 + labelGap + viewsFont.lineHeight
    )
    /// Shorts are 9:16; the poster keeps that ratio at any width.
    static let aspectRatio: CGFloat = 16.0 / 9.0

    private let poster = ThumbnailImageView(frame: .zero)
    private let titleLabel = UILabel()
    private let viewsLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        applyTheme()
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

    override func prepareForReuse() {
        super.prepareForReuse()
        poster.cancel()
        poster.image = nil
    }

    func configure(with video: Video) {
        titleLabel.text = video.title
        viewsLabel.text = video.viewCount
        // The short's own first frame — feed thumbnails are landscape and
        // would sit letterboxed inside a 9:16 card.
        if let url = URL(
            string: "https://i.ytimg.com/vi/\(video.id)/frame0.jpg"
        ) {
            poster.setImage(url: url)
        }
    }

    @objc
    private func applyTheme() {
        let theme = ThemeManager.shared
        titleLabel.textColor = theme.primaryText
        viewsLabel.textColor = theme.secondaryText
        poster.backgroundColor = theme.thumbnailPlaceholder
    }

    private func setupViews() {
        poster.contentMode = .scaleAspectFill
        poster.layer.cornerRadius = 8
        poster.clipsToBounds = true
        titleLabel.font = Self.titleFont
        titleLabel.numberOfLines = 2
        viewsLabel.font = Self.viewsFont

        let stack = UIStackView(arrangedSubviews: [
            poster, titleLabel, viewsLabel
        ])
        stack.axis = .vertical
        stack.spacing = Self.labelGap
        stack.setCustomSpacing(Self.posterGap, after: poster)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor
            ),
            poster.heightAnchor.constraint(
                equalTo: poster.widthAnchor, multiplier: Self.aspectRatio
            )
        ])
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
