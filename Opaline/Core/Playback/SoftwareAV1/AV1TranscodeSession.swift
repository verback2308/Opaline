import Foundation

/// Serves one AV1 video track to AVPlayer as H.264, segment by segment, for
/// whichever delivery is playing it (byte ranges or SABR). The delivery
/// supplies the source bytes; this owns the transcoder, a small cache, and
/// a lookahead that keeps the next segments transcoding while the current
/// one plays — software decode has to stay ahead of the playhead.
final class AV1TranscodeSession {
    typealias Completion = (Data?) -> Void
    /// Fetches the source init segment (`nil` index) or media segment `index`.
    typealias SourceFetch = (_ index: Int?, _ completion: @escaping Completion) -> Void

    private static let lookahead = 2
    private static let cacheLimit = 6

    private let fetchSource: SourceFetch
    private let segmentCount: Int
    private let fps: Int
    /// State only — every hop here is short, so cache hits never wait.
    private let queue = DispatchQueue(label: "com.ytvlite.av1-session", qos: .userInitiated)
    /// The transcodes themselves, one at a time.
    private let work = DispatchQueue(label: "com.ytvlite.av1-transcode", qos: .userInitiated)
    /// The segment on the work queue right now, if any.
    private var transcoding: Int?
    private var transcoder: AV1SegmentTranscoder?
    private var initData: Data?
    private var initWaiters: [Completion] = []
    private var cache: [Int: Data] = [:]
    private var waiters: [Int: [Completion]] = [:]
    private var sources: [Int: Data] = [:]
    private var fetching = Set<Int>()

    init(segmentCount: Int, fps: Int, fetchSource: @escaping SourceFetch) {
        self.segmentCount = segmentCount
        self.fps = fps
        self.fetchSource = fetchSource
    }

    func initSegment(completion: @escaping Completion) {
        queue.async {
            self.withTranscoder { completion($0 == nil ? nil : self.initData) }
        }
    }

    /// The CODECS value for the playlist, once the transcoder exists.
    func codecs(completion: @escaping (String?) -> Void) {
        queue.async {
            self.withTranscoder { completion($0?.codecs) }
        }
    }

    func segment(_ index: Int, completion: @escaping Completion) {
        queue.async {
            self.withTranscoder { transcoder in
                guard transcoder != nil else {
                    completion(nil)
                    return
                }
                self.request(index, completion: completion)
                for ahead in 1...Self.lookahead {
                    self.request(index + ahead, completion: nil)
                }
            }
        }
    }

    // MARK: - Queue-confined

    /// Runs `body` once the transcoder exists, building it from the source
    /// init segment on first use.
    private func withTranscoder(_ body: @escaping (AV1SegmentTranscoder?) -> Void) {
        if transcoder != nil || initData != nil {
            body(transcoder)
            return
        }
        initWaiters.append { _ in body(self.transcoder) }
        guard initWaiters.count == 1 else {
            return
        }
        fetchSource(nil) { data in
            self.queue.async { self.finishInit(data) }
        }
    }

    private func finishInit(_ source: Data?) {
        if let source, let built = AV1SegmentTranscoder(initSegment: source, fps: fps) {
            transcoder = built
            initData = built.initSegment()
        } else {
            AppLog.hls("av1: could not set up the transcoder")
            initData = Data()
        }
        let pending = initWaiters
        initWaiters = []
        pending.forEach { $0(initData) }
    }

    private func request(_ index: Int, completion: Completion?) {
        guard index >= 0, index < segmentCount else {
            completion?(nil)
            return
        }
        if let cached = cache[index] {
            completion?(cached)
            return
        }
        waiters[index, default: []] += completion.map { [$0] } ?? []
        guard sources[index] == nil, !fetching.contains(index), transcoding != index else {
            return
        }
        fetching.insert(index)
        fetchSource(index) { data in
            self.queue.async { self.sourceArrived(index, data: data) }
        }
    }

    private func sourceArrived(_ index: Int, data: Data?) {
        fetching.remove(index)
        guard let data else {
            finish(index, output: nil)
            return
        }
        sources[index] = data
        pump()
    }

    /// Starts the next transcode on the work queue: a segment the player is
    /// waiting on first, otherwise strictly in order — when the next one in
    /// line is still downloading, it waits for it rather than skipping ahead.
    private func pump() {
        guard transcoding == nil, let index = nextIndex(), let source = sources[index] else {
            return
        }
        sources[index] = nil
        transcoding = index
        work.async {
            let output = self.transcode(index, source: source)
            self.queue.async {
                self.transcoding = nil
                self.finish(index, output: output)
                self.pump()
            }
        }
    }

    private func nextIndex() -> Int? {
        let ready = Set(sources.keys)
        if let wanted = ready.filter({ !(waiters[$0] ?? []).isEmpty }).min() {
            return wanted
        }
        guard let lowest = ready.union(fetching).min(), ready.contains(lowest) else {
            return nil
        }
        return lowest
    }

    private func transcode(_ index: Int, source: Data) -> Data? {
        let sequence = UInt32(index + 1)
        guard let (output, stats) = transcoder?.transcode(source, sequence: sequence) else {
            return nil
        }
        let timing = String(format: "%.2fs (%.0f fps)", stats.seconds, stats.framesPerSecond)
        AppLog.hls("av1 seg \(index): \(stats.frames) frames in \(timing)")
        return output
    }

    private func finish(_ index: Int, output: Data?) {
        if let output {
            store(output, at: index)
        }
        let pending = waiters.removeValue(forKey: index) ?? []
        pending.forEach { $0(output) }
    }

    /// Keeps the segments nearest the one just made; AVPlayer re-asks for
    /// recent ones after a stall, rarely for anything far behind.
    private func store(_ data: Data, at index: Int) {
        cache[index] = data
        while cache.count > Self.cacheLimit {
            guard let farthest = cache.keys.max(by: { abs($0 - index) < abs($1 - index) }) else {
                break
            }
            cache.removeValue(forKey: farthest)
        }
    }
}
