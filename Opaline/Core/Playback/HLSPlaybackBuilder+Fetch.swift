import Foundation

// MARK: - Ranged fetches and visitor identity health

extension HLSPlaybackBuilder {
    /// Bytes a throttled visitor identity is allowed before googlevideo cuts
    /// it off — about 65 s of media, ~1 MiB of audio. Asking for more than
    /// this in one range is refused outright, which is what the probe leans on.
    private static let throttleWindowBytes: Int64 = 1_050_000

    /// A HEAD asking for a range twice the throttle window. A flagged identity
    /// refuses it with 403; a clean one answers 206. HEAD carries no body, so
    /// the probe costs nothing and does not spend the window either way.
    ///
    /// The offset does not matter — the limit counts bytes served, not how far
    /// into the file they are, which is why probing a single byte high up in
    /// the file said "healthy" for identities that then died ten seconds in.
    static func probeIdentity(
        input: BuildInput,
        completion: @escaping (Bool) -> Void
    ) {
        let start = Int64(input.audioFormat.indexRangeEnd) + 1
        let end = start + throttleWindowBytes * 2
        // A file shorter than the window can never hit it — nothing to probe.
        guard end < input.audioFormat.contentLength else {
            completion(true)
            return
        }
        let probe = RangeRequest(
            url: input.audioURL,
            start: start,
            end: end,
            headers: input.headers
        )
        headStatus(of: probe) { code in
            // Only an outright 403 means "this identity is throttled". A
            // transport error reports 0 — unknown, not guilty: burning an
            // identity over flaky wifi would churn for nothing.
            let healthy = code != 403
            AppLog.hls(
                "identity probe: \(healthy ? "ok" : "throttled")"
                    + " (HTTP \(code))"
            )
            if !healthy {
                InnertubeSession.invalidateVisitorIdentity(
                    reason: "googlevideo throttle"
                )
            }
            completion(healthy)
        }
    }

    /// Status code of a HEAD for the given range. Reports 0 when the request
    /// could not be made at all, which the caller reads as "cannot tell".
    private static func headStatus(
        of request: RangeRequest,
        completion: @escaping (Int) -> Void
    ) {
        var urlReq = URLRequest(url: request.url)
        urlReq.httpMethod = "HEAD"
        for (key, value) in request.headers {
            urlReq.setValue(value, forHTTPHeaderField: key)
        }
        urlReq.setValue(
            "bytes=\(request.start)-\(request.end)",
            forHTTPHeaderField: HTTPHeader.range
        )
        let task = URLSession.shared.dataTask(
            with: urlReq
        ) { _, response, error in
            if let error {
                AppLog.hls(
                    "identity probe failed: \(error.localizedDescription)"
                )
            }
            completion((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        task.resume()
    }

    /// Fetch a byte range from a URL with custom headers. `strict` answers
    /// an error status with nil rather than with the error page's body.
    static func fetchRangeData(
        request: RangeRequest,
        strict: Bool = false,
        completion: @escaping (Data?) -> Void
    ) {
        var urlReq = URLRequest(url: request.url)
        for (headerKey, headerVal) in request.headers {
            urlReq.setValue(headerVal, forHTTPHeaderField: headerKey)
        }
        let rv = "bytes=\(request.start)-\(request.end)"
        urlReq.setValue(rv, forHTTPHeaderField: HTTPHeader.range)
        let task = URLSession.shared.dataTask(with: urlReq) { data, response, error in
            if let error {
                AppLog.hls("range fetch failed: \(error.localizedDescription)")
                completion(nil)
                return
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let failed = code != 206 && code != 200
            if failed {
                logRangeFailure(code: code, request: request, http: http, data: data)
            }
            completion(failed && strict ? nil : data)
        }
        task.resume()
    }
}
