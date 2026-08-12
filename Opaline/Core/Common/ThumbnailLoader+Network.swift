import Foundation
import UIKit

private struct ThumbnailNetworkResponse {
    let request: ThumbnailRequest
    let index: Int
    let token: CancellationToken
    let result: Result<HTTPResponse, Error>
    let startedAt: Date
    let completion: ((Result<ThumbnailLoadResult, Error>) -> Void)?
}

extension ThumbnailLoader {
    func loadCandidate(
        request: ThumbnailRequest,
        index: Int,
        token: CancellationToken,
        completion: ((Result<ThumbnailLoadResult, Error>) -> Void)?
    ) {
        guard !token.isCancelled else {
            return
        }
        guard index < request.candidates.count else {
            complete(
                .failure(ThumbnailLoaderError.unavailable),
                token: token,
                completion: completion
            )
            return
        }
        if loadCachedCandidate(
            request: request,
            index: index,
            token: token,
            completion: completion
        ) {
            return
        }
        fetchCandidate(
            request: request,
            index: index,
            token: token,
            completion: completion
        )
    }

    private func loadCachedCandidate(
        request: ThumbnailRequest,
        index: Int,
        token: CancellationToken,
        completion: ((Result<ThumbnailLoadResult, Error>) -> Void)?
    ) -> Bool {
        let url = request.candidates[index]
        if isKnownMissing(url) {
            loadCandidate(
                request: request,
                index: index + 1,
                token: token,
                completion: completion
            )
            return true
        }
        let key = request.cacheKey(for: url)
        if completeMemoryHit(
            key: key,
            url: url,
            token: token,
            completion: completion
        ) {
            return true
        }
        return loadDiskCandidate(
            request: request,
            index: index,
            token: token,
            completion: completion
        )
    }

    private func loadDiskCandidate(
        request: ThumbnailRequest,
        index: Int,
        token: CancellationToken,
        completion: ((Result<ThumbnailLoadResult, Error>) -> Void)?
    ) -> Bool {
        let url = request.candidates[index]
        let key = request.cacheKey(for: url)
        guard cachingEnabled,
              let fileURL = diskCache.fileURL(for: url)
        else {
            return false
        }
        guard let image = decodeDiskImage(
            fileURL: fileURL,
            request: request,
            index: index
        ) else {
            diskCache.remove(url: url.absoluteString)
            return false
        }
        memoryCache.setObject(
            image,
            forKey: key,
            cost: image.memoryCost
        )
        complete(
            .success(makeResult(image: image, url: url)),
            token: token,
            completion: completion
        )
        return true
    }

    private func decodeDiskImage(
        fileURL: URL,
        request: ThumbnailRequest,
        index: Int
    ) -> UIImage? {
        guard let image = decode(
            fileURL: fileURL,
            maxPixelSize: request.maxPixelSize
        ),
        isAdequate(
            image: image,
            request: request,
            index: index
        )
        else {
            return nil
        }
        return image
    }

    private func completeMemoryHit(
        key: String,
        url: URL,
        token: CancellationToken,
        completion: ((Result<ThumbnailLoadResult, Error>) -> Void)?
    ) -> Bool {
        guard let image = memoryCache.object(forKey: key) else {
            return false
        }
        complete(
            .success(makeResult(image: image, url: url)),
            token: token,
            completion: completion
        )
        return true
    }

    private func fetchCandidate(
        request: ThumbnailRequest,
        index: Int,
        token: CancellationToken,
        completion: ((Result<ThumbnailLoadResult, Error>) -> Void)?
    ) {
        let url = request.candidates[index]
        let startedAt = Date()
        transport.send(
            HTTPRequest(method: .get, url: url),
            cancellationToken: token
        ) { [weak self] result in
            self?.decodeQueue.async {
                self?.handleNetworkResponse(
                    ThumbnailNetworkResponse(
                        request: request,
                        index: index,
                        token: token,
                        result: result,
                        startedAt: startedAt,
                        completion: completion
                    )
                )
            }
        }
    }

    private func handleNetworkResponse(
        _ response: ThumbnailNetworkResponse
    ) {
        guard !response.token.isCancelled else {
            return
        }
        let url = response.request.candidates[response.index]
        rememberMissingIfNeeded(response.result, url: url)
        guard let result = try? response.result.get(),
              (200..<300).contains(result.status),
              let image = decode(
                  data: result.data,
                  maxPixelSize: response.request.maxPixelSize
              ),
              isAdequate(
                  image: image,
                  request: response.request,
                  index: response.index
              )
        else {
            loadNextCandidate(after: response)
            return
        }
        completeNetworkSuccess(
            response: response,
            result: result,
            image: image,
            url: url
        )
    }

    private func loadNextCandidate(
        after response: ThumbnailNetworkResponse
    ) {
        loadCandidate(
            request: response.request,
            index: response.index + 1,
            token: response.token,
            completion: response.completion
        )
    }

    private func isAdequate(
        image: UIImage,
        request: ThumbnailRequest,
        index: Int
    ) -> Bool {
        guard index < request.candidates.count - 1 else {
            return true
        }
        let longestSide = max(
            image.cgImage?.width ?? 0,
            image.cgImage?.height ?? 0
        )
        return longestSide >= min(request.maxPixelSize, 480)
    }

    private func completeNetworkSuccess(
        response: ThumbnailNetworkResponse,
        result: HTTPResponse,
        image: UIImage,
        url: URL
    ) {
        storeNetworkImage(
            image: image,
            data: result.data,
            request: response.request,
            url: url
        )
        logSuccess(url: url, image: image, startedAt: response.startedAt)
        complete(
            .success(makeResult(image: image, url: url)),
            token: response.token,
            completion: response.completion
        )
    }

    private func storeNetworkImage(
        image: UIImage,
        data: Data,
        request: ThumbnailRequest,
        url: URL
    ) {
        let key = request.cacheKey(for: url)
        memoryCache.setObject(image, forKey: key, cost: image.memoryCost)
        if cachingEnabled {
            diskCache.store(data: data, for: url)
        }
    }

    private func complete(
        _ result: Result<ThumbnailLoadResult, Error>,
        token: CancellationToken,
        completion: ((Result<ThumbnailLoadResult, Error>) -> Void)?
    ) {
        guard let completion else {
            return
        }
        DispatchQueue.main.async {
            guard !token.isCancelled else {
                return
            }
            completion(result)
        }
    }

    private func makeResult(
        image: UIImage,
        url: URL
    ) -> ThumbnailLoadResult {
        ThumbnailLoadResult(
            image: image,
            sourceURL: url,
            pixelWidth: image.cgImage?.width ?? 0,
            pixelHeight: image.cgImage?.height ?? 0
        )
    }
}
