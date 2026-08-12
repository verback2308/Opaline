import UIKit

/// The Shorts row on the subscriptions screen: a titled band of vertical
/// cards that scrolls sideways. Shorts live only here — mixed into the main
/// list they were shown with landscape thumbnails, which fit them badly.
final class ShortsShelfCell: UITableViewCell {
    static let reuseId = "ShortsShelfCell"
    /// Card width; the poster's 9:16 ratio drives the rest of the height.
    private static let cardWidth: CGFloat = 128
    private static let inset: CGFloat = 16

    static var rowHeight: CGFloat {
        cardWidth * ShortThumbnailCell.aspectRatio
            + ShortThumbnailCell.captionHeight + headerHeight + inset
    }

    private static let headerHeight: CGFloat = 36

    var onSelect: ((Int) -> Void)?
    var onSeeAll: (() -> Void)?

    private let titleLabel = UILabel()
    private let seeAllButton = UIButton(type: .system)
    private let collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 10
        layout.sectionInset = UIEdgeInsets(
            top: 0, left: inset, bottom: 0, right: inset
        )
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear
        return view
    }()

    private var shorts: [Video] = []

    private var headerConstraints: [NSLayoutConstraint] {
        [
            titleLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Self.inset
            ),
            titleLabel.topAnchor.constraint(
                equalTo: contentView.topAnchor, constant: 8
            ),
            seeAllButton.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Self.inset
            ),
            seeAllButton.centerYAnchor.constraint(
                equalTo: titleLabel.centerYAnchor
            )
        ]
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
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

    func configure(with shorts: [Video]) {
        self.shorts = shorts
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    @objc
    private func applyTheme() {
        let theme = ThemeManager.shared
        backgroundColor = theme.background
        contentView.backgroundColor = theme.background
        titleLabel.textColor = theme.primaryText
        seeAllButton.setTitleColor(theme.secondaryText, for: .normal)
    }

    @objc
    private func handleSeeAll() {
        onSeeAll?()
    }

    private func setupHeader() {
        titleLabel.text = "shorts.shelf.title".localized
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Same wording as the channel bar's button — one "All" for the app.
        seeAllButton.setTitle("subscriptions.allButton".localized, for: .normal)
        seeAllButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        seeAllButton.translatesAutoresizingMaskIntoConstraints = false
        seeAllButton.addTarget(
            self, action: #selector(handleSeeAll), for: .touchUpInside
        )
    }

    private func setupViews() {
        setupHeader()
        setupCollection()
        contentView.addSubview(titleLabel)
        contentView.addSubview(seeAllButton)
        contentView.addSubview(collectionView)
        NSLayoutConstraint.activate(headerConstraints + [
            collectionView.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor, constant: 8
            ),
            collectionView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor
            ),
            collectionView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor
            ),
            collectionView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor
            )
        ])
    }

    private func setupCollection() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            ShortThumbnailCell.self,
            forCellWithReuseIdentifier: ShortThumbnailCell.reuseIdentifier
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Collection

extension ShortsShelfCell: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        shorts.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ShortThumbnailCell.reuseIdentifier,
            for: indexPath
        )
        (cell as? ShortThumbnailCell)?.configure(with: shorts[indexPath.item])
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(
            width: Self.cardWidth,
            height: collectionView.bounds.height
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        onSelect?(indexPath.item)
    }
}
