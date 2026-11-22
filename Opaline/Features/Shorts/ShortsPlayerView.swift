import AVFoundation
import UIKit

/// The one player the Shorts feed owns, moved between cells as the user
/// swipes. Deliberately minimal — a short needs playback, looping and a tap
/// to pause, not the watch screen's quality menus, seek bar or PiP.
///
/// An `AVQueuePlayer` so the next short pre-rolls in the same player: handing
/// a prepared item over from a second one throws, AVFoundation detaches
/// asynchronously (see [[ShortsPrefetcher]]). `actionAtItemEnd` is `.pause`,
/// a queued short must not start on its own.
final class ShortsPlayerView: UIView {
    /// One queued short. Source and loader are retained while the item is in
    /// the queue — dropping either kills the stream.
    struct Entry {
        let videoId: String
        let item: AVPlayerItem
        let source: VideoSource?
        let loader: AVAssetResourceLoaderDelegate?
    }

    /// Seconds of video kept ahead of the playhead. The watch screen's 20
    /// makes the player fill a buffer longer than the short itself before it
    /// starts — the delay between the swipe and the picture.
    private static let forwardBuffer: TimeInterval = 3
    /// How much shorter than its region a short may be and still fill it.
    /// 9:16 against the region is 0.90 and fills; 1:1 is 0.51 and does not.
    private static let minFillRatio: CGFloat = 0.75

    override static var layerClass: AnyClass { AVPlayerLayer.self }

    let facade = PlaybackFacade()
    let player = AVQueuePlayer() // internal for the 2x hold, see ShortsSpeedBoost
    /// Internal, not private: the PlaybackContext conformance writes it
    /// from ShortsPlayerView+Playback.swift.
    let statusLabel = UILabel()
    private var timeObserver: Any?
    /// Mirrors the player's queue: index 0 is playing, 1 is pre-rolling.
    private var entries: [Entry] = []
    /// The item whose first frame is awaited; nil once it has been drawn.
    var awaitedItem: AVPlayerItem?

    var isPaused: Bool { player.rate == 0 }

    /// Playback position as a 0...1 fraction, for the controller's progress
    /// bar — which lives up there so it clears the tab bar.
    var onProgress: ((Double) -> Void)?

    /// The short already queued behind the current one, if any.
    var queuedVideoId: String? {
        entries.count > 1 ? entries[1].videoId : nil
    }

    private var playerLayer: AVPlayerLayer? {
        layer as? AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Opaque: a fitted short would otherwise show the cell's poster in
        // the bands beside it, doubling the picture. Covering the poster
        // until the first frame is `alpha`'s job now.
        backgroundColor = .black
        playerLayer?.player = player
        playerLayer?.videoGravity = .resizeAspectFill
        // Keep the stalling policy on: without it a `play()` that lands
        // before any data has arrived leaves the rate at zero and never
        // resumes, so a swiped-to short sits on its poster until tapped.
        PlaybackBufferPolicy.configure(player: player)
        player.actionAtItemEnd = .pause
        facade.context = self
        setupStatusLabel()
        setupTimeObserver()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Playback control

    func load(videoId: String, watchService: WatchService) {
        stop()
        facade.start(
            videoId: videoId,
            apiClient: watchService,
            cancellationToken: CancellationToken()
        )
    }

    /// Plays an already-resolved short with no round trip. The facade is told
    /// what plays so mid-playback recovery still has a source to fall back on.
    func attach(
        source: VideoSource,
        playback: PreparedPlayback,
        videoId: String,
        watchService: WatchService
    ) {
        stop()
        facade.currentVideoId = videoId
        facade.currentApiClient = watchService
        facade.activeVideoSource = source
        play(entry: Entry(
            videoId: videoId,
            item: playback.item,
            source: source,
            loader: playback.resourceLoader
        ))
    }

    /// Queues a resolved short so the player pre-rolls it — one swipe ahead.
    func enqueue(
        source: VideoSource,
        playback: PreparedPlayback,
        videoId: String
    ) {
        guard !entries.isEmpty, entries.count < 2,
              entries[0].videoId != videoId,
              player.canInsert(playback.item, after: nil) else {
            return
        }
        PlaybackBufferPolicy.configure(
            item: playback.item, forwardBufferDuration: Self.forwardBuffer
        )
        player.insert(playback.item, after: nil)
        entries.append(Entry(
            videoId: videoId,
            item: playback.item,
            source: source,
            loader: playback.resourceLoader
        ))
    }

    /// Jumps to the queued short. False when `videoId` is not the queued one
    /// — a backward or skipping swipe, which has to resolve normally.
    func advance(to videoId: String, watchService: WatchService) -> Bool {
        guard queuedVideoId == videoId else {
            return false
        }
        hideUntilFirstFrame(of: entries[1].item)
        player.advanceToNextItem()
        entries.removeFirst()
        facade.currentVideoId = videoId
        facade.currentApiClient = watchService
        facade.activeVideoSource = entries[0].source
        statusLabel.text = nil
        onProgress?(0)
        player.play()
        return true
    }

    func play(entry: Entry) {
        hideUntilFirstFrame(of: entry.item)
        PlaybackBufferPolicy.configure(
            item: entry.item, forwardBufferDuration: Self.forwardBuffer
        )
        player.removeAllItems()
        player.insert(entry.item, after: nil)
        entries = [entry]
        statusLabel.text = nil
        player.play()
    }

    /// The layer keeps drawing the last frame of whatever played before, so
    /// moving it into the next cell flashes the previous short over that
    /// short's own poster. Stay invisible until `item` itself draws — keyed on
    /// the item, because the clock keeps reporting the old one's position for
    /// a tick after it leaves the queue and that revealed an empty layer.
    private func hideUntilFirstFrame(of item: AVPlayerItem?) {
        awaitedItem = item
        alpha = 0
        // What the next short gets if its size never resolves; almost every
        // short is portrait and fills.
        setGravity(.resizeAspectFill)
    }

    func stop() {
        hideUntilFirstFrame(of: nil)
        onProgress?(0)
        player.pause()
        player.removeAllItems()
        entries = []
        facade.reset()
        statusLabel.text = nil
    }

    func setPaused(_ paused: Bool) {
        if paused {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Rotation changes which gravity is right, and the first frame — where
    /// it is otherwise decided — is long past by then.
    override func layoutSubviews() {
        super.layoutSubviews()
        applyGravity()
    }

    @objc
    private func itemDidEnd(_ note: Notification) {
        guard (note.object as? AVPlayerItem) === player.currentItem else {
            return
        }
        player.seek(to: .zero)
        player.play()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }
}

// MARK: - Layer, gravity and progress

private extension ShortsPlayerView {
    /// Fills its region unless the short is far off its shape. The region is
    /// the screen down to the tab bar, which the official app fills: a 9:16
    /// short gives up about a tenth of its width there, a crop it survives.
    /// A square one would give up half its height, so that is fitted instead.
    /// A landscape region — an iPad on its side — never fills: the crop there
    /// eats most of a portrait short, so it is fitted and takes side bands.
    func applyGravity() {
        guard let size = player.currentItem?.presentationSize,
              size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > bounds.width else {
            setGravity(.resizeAspect)
            return
        }
        let fits = size.height / size.width
            >= bounds.height / bounds.width * Self.minFillRatio
        setGravity(fits ? .resizeAspectFill : .resizeAspect)
    }

    /// Actions off: otherwise this is a quarter-second zoom that plays out
    /// after the layer is revealed rather than before it.
    func setGravity(_ gravity: AVLayerVideoGravity) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.videoGravity = gravity
        CATransaction.commit()
    }

    func setupTimeObserver() {
        // Short interval because this also drives the reveal of the new
        // short — at 0.25s the poster lingers visibly after the swipe.
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            self?.reportProgress(at: time)
        }
    }

    func reportProgress(at time: CMTime) {
        // The awaited item is current and its clock has moved off zero: it is
        // decoding, so the layer no longer holds the previous short's frame.
        if let awaited = awaitedItem, player.currentItem === awaited,
           time.seconds > 0 {
            awaitedItem = nil
            applyGravity()
            alpha = 1
        }
        guard let duration = player.currentItem?.duration,
              duration.isNumeric, duration.seconds > 0 else {
            onProgress?(0)
            return
        }
        onProgress?(time.seconds / duration.seconds)
    }

    func setupStatusLabel() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 16
            )
        ])
    }
}
