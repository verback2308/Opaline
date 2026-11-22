import Foundation

/// Serves the watch screen from the network first and from what was saved
/// with the video when the network is not there.
///
/// A decorator rather than a second client: the watch screen keeps talking to
/// one `WatchService` and never learns that a video is offline. The order is
/// network, then the in-memory cache (which does not survive a relaunch),
/// then the copy stored beside the downloaded file.
final class OfflineWatchService: WatchService {
    private let inner: WatchService
    private let cache: AppCache

    init(wrapping inner: WatchService, cache: AppCache = .shared) {
        self.inner = inner
        self.cache = cache
    }

    func fetchWatchPage(
        video: Video,
        cancellationToken: CancellationToken?,
        completion: @escaping (Result<WatchPage, Error>) -> Void
    ) {
        inner.fetchWatchPage(
            video: video, cancellationToken: cancellationToken
        ) { [weak self] result in
            guard case .failure = result, let self else {
                completion(result)
                return
            }
            completion(self.storedPage(for: video) ?? result)
        }
    }

    // A queue only exists over the network, so both go straight through.

    func fetchQueuePage(
        continuation: String,
        completion: @escaping (Result<FeedPage, Error>) -> Void
    ) {
        inner.fetchQueuePage(
            continuation: continuation,
            completion: completion
        )
    }

    func fetchShuffledQueue(
        video: Video,
        params: String,
        completion: @escaping (Result<WatchPage, Error>) -> Void
    ) {
        inner.fetchShuffledQueue(
            video: video,
            params: params,
            completion: completion
        )
    }

    private func storedPage(for video: Video) -> Result<WatchPage, Error>? {
        if let cached = cache.cachedWatchPage(videoId: video.id) {
            return .success(cached)
        }
        guard let saved = DownloadStore.page(for: video.id) else {
            return nil
        }
        AppLog.player("watch page served from the downloaded copy")
        DownloadStore.primeAvatarIfPossible(from: saved, videoId: video.id)
        return .success(offlineShaped(saved))
    }

    /// With no network there is nothing to recommend, so the rail below the
    /// video lists what else is on the device instead of sitting empty.
    private func offlineShaped(_ page: WatchPage) -> WatchPage {
        let others = DownloadStore.downloads()
            .filter { $0.id != page.video.id && DownloadStore.isDownloaded($0.id) }
        return WatchPage(
            video: page.video,
            description: page.description,
            channelInfo: page.channelInfo,
            subscribeButtonText: page.subscribeButtonText,
            isSubscribed: page.isSubscribed,
            relatedVideos: others,
            likeCount: page.likeCount,
            likeStatus: page.likeStatus,
            commentCount: page.commentCount,
            nextVideo: others.first,
            playlistTitle: nil,
            playlistVideos: nil,
            servedOffline: true,
            chapters: page.chapters
        )
    }

    // MARK: - Straight through
    //
    // Playback, captions and dubs have their own offline stories — the file
    // on disk and the tracks inside it — and nothing to add here.

    // swiftlint:disable:next function_parameter_count
    func fetchDirectPlayback(
        videoId: String,
        client: PlaybackClient,
        poToken: String?,
        cancellationToken: CancellationToken?,
        completion: @escaping (Result<DirectPlaybackInfo, Error>) -> Void
    ) {
        inner.fetchDirectPlayback(
            videoId: videoId,
            client: client,
            poToken: poToken,
            cancellationToken: cancellationToken,
            completion: completion
        )
    }

    /// Same rule as the page: the network answer wins, and what was saved
    /// with the video stands in when there is none. The saved copy holds one
    /// order, so its sort menu is dropped: a chip nobody can answer offline
    /// only empties the list the video came with.
    func fetchComments(
        videoId: String,
        continuation: String?,
        cancellationToken: CancellationToken?,
        completion: @escaping (Result<CommentsPage, Error>) -> Void
    ) {
        inner.fetchComments(
            videoId: videoId,
            continuation: continuation,
            cancellationToken: cancellationToken
        ) { result in
            guard case .failure = result,
                  let stored = DownloadStore.comments(
                      for: videoId, continuation: continuation
                  ) else {
                completion(result)
                return
            }
            AppLog.player("comments served from the downloaded copy")
            completion(.success(CommentsPage(
                title: stored.title,
                comments: stored.comments,
                continuation: stored.continuation,
                sortOptions: []
            )))
        }
    }

    func fetchWatchtimeURLs(
        videoId: String,
        completion: @escaping (WatchtimeURLs?) -> Void
    ) {
        inner.fetchWatchtimeURLs(videoId: videoId, completion: completion)
    }

    /// This one reports failure as an empty list, so "nothing came back" is
    /// what the fallback keys on.
    func fetchCaptionTracks(
        videoId: String,
        completion: @escaping ([SubtitleTrack]) -> Void
    ) {
        inner.fetchCaptionTracks(videoId: videoId) { tracks in
            guard tracks.isEmpty,
                  let stored = DownloadStore.captionTracks(for: videoId) else {
                completion(tracks)
                return
            }
            AppLog.player("caption tracks served from the downloaded copy")
            completion(stored)
        }
    }

    func fetchAudioTrackList(
        videoId: String,
        completion: @escaping ([AudioTrackInfo]) -> Void
    ) {
        inner.fetchAudioTrackList(videoId: videoId, completion: completion)
    }
}
