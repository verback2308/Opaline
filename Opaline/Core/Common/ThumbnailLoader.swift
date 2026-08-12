import UIKit

struct ThumbnailLoadResult {
    let image: UIImage
    let sourceURL: URL
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ThumbnailLoaderError: Error {
    case unavailable
}

final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    let memoryCache = ImageMemoryCache()
    let diskCache = ImageDiskCache()
    var transport: HTTPTransport
    let decodeQueue = DispatchQueue(
        label: "com.ytvlite.thumbnail-decode",
        qos: .utility
    )
    var prefetchTokens: [String: CancellationToken] = [:]
    let prefetchLock = NSLock()
    var missingCandidates = Set<String>()

    var cachingEnabled: Bool {
        UserDefaults.standard.object(
            forKey: UserDefaultsKeys.Cache.imageCacheEnabled
        ) as? Bool ?? true
    }

    init(transport: HTTPTransport = ServiceContainer.mediaTransport) {
        self.transport = transport
    }

    @discardableResult
    func load(
        url: URL,
        maxPixelSize: Int,
        completion: @escaping (Result<ThumbnailLoadResult, Error>) -> Void,
        videoId: String? = nil
    ) -> CancellationToken {
        let request = ThumbnailRequest(
            url: url,
            maxPixelSize: maxPixelSize,
            videoId: videoId
        )
        let token = CancellationToken()
        decodeQueue.async { [weak self] in
            self?.loadCandidate(
                request: request,
                index: 0,
                token: token,
                completion: completion
            )
        }
        return token
    }

    func prefetch(
        url: URL,
        maxPixelSize: Int,
        videoId: String? = nil
    ) {
        let request = ThumbnailRequest(
            url: url,
            maxPixelSize: maxPixelSize,
            videoId: videoId
        )
        let identity = request.identity
        prefetchLock.lock()
        guard prefetchTokens[identity] == nil else {
            prefetchLock.unlock()
            return
        }
        let token = CancellationToken()
        prefetchTokens[identity] = token
        prefetchLock.unlock()
        decodeQueue.async { [weak self] in
            self?.loadCandidate(
                request: request,
                index: 0,
                token: token
            ) { [weak self] _ in
                self?.finishPrefetch(identity: identity, token: token)
            }
        }
    }

    func cancelPrefetch(
        url: URL,
        maxPixelSize: Int,
        videoId: String? = nil
    ) {
        let identity = ThumbnailRequest(
            url: url,
            maxPixelSize: maxPixelSize,
            videoId: videoId
        ).identity
        prefetchLock.lock()
        let token = prefetchTokens.removeValue(forKey: identity)
        prefetchLock.unlock()
        token?.cancel()
    }

    func clearCache() {
        memoryCache.removeAll()
        diskCache.clear()
        prefetchLock.lock()
        missingCandidates.removeAll()
        prefetchLock.unlock()
    }

    func invalidate(url: URL) {
        let request = ThumbnailRequest(
            url: url,
            maxPixelSize: ThumbnailSizing.defaultPixelSize
        )
        for candidate in request.candidates {
            for pixelSize in 1...ThumbnailSizing.maximumPixelSize {
                memoryCache.remove(
                    url: "\(candidate.absoluteString)#\(pixelSize)"
                )
            }
            diskCache.remove(url: candidate.absoluteString)
            prefetchLock.lock()
            missingCandidates.remove(candidate.absoluteString)
            prefetchLock.unlock()
        }
    }

    func isKnownMissing(_ url: URL) -> Bool {
        prefetchLock.lock()
        defer { prefetchLock.unlock() }
        return missingCandidates.contains(url.absoluteString)
    }

    func rememberMissing(_ url: URL) {
        prefetchLock.lock()
        missingCandidates.insert(url.absoluteString)
        prefetchLock.unlock()
    }

    func rememberMissingIfNeeded(
        _ result: Result<HTTPResponse, Error>,
        url: URL
    ) {
        guard let response = try? result.get(),
              response.status == 404
        else {
            return
        }
        rememberMissing(url)
    }

    func logSuccess(
        url: URL,
        image: UIImage,
        startedAt: Date
    ) {
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let width = image.cgImage?.width ?? 0
        let height = image.cgImage?.height ?? 0
        AppLog.img(
            "loaded \(url.lastPathComponent) "
                + "\(width)x\(height) \(elapsed)ms"
        )
    }

    func finishPrefetch(
        identity: String,
        token: CancellationToken
    ) {
        prefetchLock.lock()
        if prefetchTokens[identity] === token {
            prefetchTokens[identity] = nil
        }
        prefetchLock.unlock()
    }
}
