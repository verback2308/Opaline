import AVFoundation

// MARK: - AVAssetResourceLoaderDelegate

final class HLSPlaylistLoader: NSObject,
    AVAssetResourceLoaderDelegate {
    let loaderQueue = DispatchQueue(
        label: "com.ytvlite.hls-loader"
    )

    private var playlists: [String: Data] = [:]
    /// Whatever else must live as long as the item does — the transcoding
    /// server when the video track is software AV1.
    var keepAlive: AnyObject?

    /// Register playlist content for a given path.
    func register(path: String, content: String) {
        playlists[path] = Data(content.utf8)
    }

    /// A playlist registered earlier, for serving it some other way.
    func playlist(at path: String) -> Data? {
        playlists[path]
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource
        request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = request.request.url else {
            return false
        }
        AppLog.hls("request: \(url.absoluteString)")
        guard url.scheme == HLSGenerator.scheme else {
            let sch = url.scheme ?? "nil"
            AppLog.hls("non-custom scheme: \(sch)")
            return false
        }
        guard let key = resolvePlaylistKey(from: url) else {
            logUnknownPath(url)
            let err = NSError(
                domain: "HLSPlaylistLoader",
                code: -1,
                userInfo: nil
            )
            request.finishLoading(with: err)
            return true
        }
        guard let data = playlists[key] else {
            return false
        }
        AppLog.hls("serving \(key) (\(data.count) bytes)")
        fillLoadingRequest(request, with: data)
        request.finishLoading()
        return true
    }

    // MARK: - Private Helpers

    private func resolvePlaylistKey(
        from url: URL
    ) -> String? {
        if let host = url.host, playlists[host] != nil {
            return host
        }
        let trimmed = String(url.path.dropFirst())
        if playlists[trimmed] != nil {
            return trimmed
        }
        return nil
    }

    private func logUnknownPath(_ url: URL) {
        let host = url.host ?? "nil"
        let keys = Array(playlists.keys)
        AppLog.hls(
            "unknown: host=\(host)"
                + " path=\(url.path)"
                + " keys=\(keys)"
        )
    }

    private func fillLoadingRequest(
        _ request: AVAssetResourceLoadingRequest,
        with data: Data
    ) {
        if let info = request.contentInformationRequest {
            info.contentType = "public.m3u-playlist"
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        if let dataReq = request.dataRequest {
            let off = Int(dataReq.requestedOffset)
            let len = responseLength(
                dataReq: dataReq,
                offset: off,
                dataCount: data.count
            )
            if off < data.count, len > 0 {
                let range = off..<(off + len)
                dataReq.respond(
                    with: data.subdata(in: range)
                )
            }
        }
    }

    private func responseLength(
        dataReq: AVAssetResourceLoadingDataRequest,
        offset: Int,
        dataCount: Int
    ) -> Int {
        if dataReq.requestsAllDataToEndOfResource {
            return dataCount - offset
        }
        return min(dataReq.requestedLength, dataCount - offset)
    }
}

// MARK: - Data Big-Endian Helpers

// Offsets below are relative to the start of the data, and `Data` is not
// always indexed from zero — a slice keeps its parent's indices. Every access
// therefore goes through `startIndex`.
extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func readBigUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            return 0
        }
        return UInt32(byte(at: offset)) << 24
            | UInt32(byte(at: offset + 1)) << 16
            | UInt32(byte(at: offset + 2)) << 8
            | UInt32(byte(at: offset + 3))
    }

    func readBigUInt64(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else {
            return 0
        }
        return (0..<8).reduce(UInt64(0)) { value, index in
            value << 8 | UInt64(byte(at: offset + index))
        }
    }

    func readFourCC(at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= count else {
            return ""
        }
        let base = startIndex + offset
        return String(bytes: self[base..<(base + 4)], encoding: .ascii) ?? ""
    }
}
