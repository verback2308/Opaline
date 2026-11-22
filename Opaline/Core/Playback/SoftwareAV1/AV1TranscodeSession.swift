import Foundation

/// Serves one AV1 video track to AVPlayer as H.264, chunk by chunk (see
/// [[AV1ChunkPlan]]), for whichever delivery is playing it — byte ranges or
/// SABR. The delivery supplies the source bytes; this owns the transcoder,
/// a small cache, and a lookahead that keeps the next segments transcoding
/// while the current one plays: software decode has to stay ahead.
final class AV1TranscodeSession {
    typealias Completion = (Data?) -> Void
    /// Fetches the source init segment (`nil` index) or media segment `index`.
    typealias SourceFetch = (_ index: Int?, _ completion: @escaping Completion) -> Void

    private static let lookahead = 2
    private static let cacheLimit = 24

    let plan: AV1ChunkPlan
    private let fetchSource: SourceFetch
    private let fps: Int
    /// State only — every hop here is short, so cache hits never wait.
    private let queue = DispatchQueue(label: "com.ytvlite.av1-session", qos: .userInitiated)
    /// The transcodes themselves, one at a time.
    private let work = DispatchQueue(label: "com.ytvlite.av1-transcode", qos: .userInitiated)
    private var transcoder: AV1SegmentTranscoder?
    private var initData: Data?
    private var initWaiters: [Completion] = []
    private var cache: [AV1ChunkID: Data] = [:]
    private var waiters: [AV1ChunkID: [Completion]] = [:]
    private var sources: [Int: Data] = [:]
    private var fetching = Set<Int>()
    /// The segment on the work queue right now, if any.
    private var transcoding: Int?

    init(plan: AV1ChunkPlan, fps: Int, fetchSource: @escaping SourceFetch) {
        self.plan = plan
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

    func chunk(_ id: AV1ChunkID, completion: @escaping Completion) {
        queue.async {
            self.withTranscoder { transcoder in
                guard transcoder != nil else {
                    completion(nil)
                    return
                }
                self.request(id, completion: completion)
                for ahead in 1...Self.lookahead {
                    self.prepare(id.segment + ahead)
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

    private func request(_ id: AV1ChunkID, completion: @escaping Completion) {
        if let cached = cache[id] {
            completion(cached)
            return
        }
        waiters[id, default: []].append(completion)
        prepare(id.segment)
    }

    /// Makes sure a segment is on its way: downloading, queued or being
    /// transcoded. A segment whose chunks are all cached needs nothing.
    private func prepare(_ segment: Int) {
        guard plan.counts.indices.contains(segment),
              sources[segment] == nil, !fetching.contains(segment), transcoding != segment,
              !isCached(segment) || hasWaiters(segment) else {
            return
        }
        fetching.insert(segment)
        fetchSource(segment) { data in
            self.queue.async { self.sourceArrived(segment, data: data) }
        }
    }

    private func sourceArrived(_ segment: Int, data: Data?) {
        fetching.remove(segment)
        guard let data else {
            failWaiters(of: segment)
            return
        }
        sources[segment] = data
        pump()
    }

    /// Starts the next transcode on the work queue: a segment the player is
    /// waiting on first, otherwise strictly in order — when the next one in
    /// line is still downloading, it waits for it rather than skipping ahead.
    private func pump() {
        guard transcoding == nil, let segment = nextSegment(), let source = sources[segment] else {
            return
        }
        sources[segment] = nil
        transcoding = segment
        let chunks = ChunkRequest(
            count: plan.chunkCount(of: segment),
            first: firstWanted(in: segment)
        )
        work.async {
            let onChunk: (Int, Data) -> Void = { chunk, data in
                let id = AV1ChunkID(segment: segment, chunk: chunk)
                self.queue.async { self.deliver(id, data) }
            }
            let stats = self.transcoder?.transcode(
                source,
                index: segment,
                plan: chunks,
                onChunk: onChunk
            )
            self.queue.async { self.finishSegment(segment, stats: stats) }
        }
    }

    private func nextSegment() -> Int? {
        let ready = Set(sources.keys)
        if let wanted = ready.filter(hasWaiters).min() {
            return wanted
        }
        guard let lowest = ready.union(fetching).min(), ready.contains(lowest) else {
            return nil
        }
        return lowest
    }

    private func deliver(_ id: AV1ChunkID, _ data: Data) {
        store(data, at: id)
        let pending = waiters.removeValue(forKey: id) ?? []
        pending.forEach { $0(data) }
    }

    private func finishSegment(_ segment: Int, stats: TranscodeStats?) {
        transcoding = nil
        if let stats {
            let timing = String(format: "%.2fs (%.0f fps)", stats.seconds, stats.framesPerSecond)
            AppLog.hls("av1 seg \(segment): \(stats.frames) frames in \(timing)")
        }
        // Anyone still waiting on this segment asked for a chunk it did not
        // produce — answer rather than leave the player hanging.
        failWaiters(of: segment)
        pump()
    }

    private func failWaiters(of segment: Int) {
        for id in waiters.keys where id.segment == segment {
            waiters.removeValue(forKey: id)?.forEach { $0(nil) }
        }
    }

    /// The earliest chunk anyone is waiting for — a start or seek into the
    /// middle of a segment skips encoding what lies before it. A segment
    /// nobody waits on yet (lookahead) is made whole.
    private func firstWanted(in segment: Int) -> Int {
        waiters.filter { $0.key.segment == segment && !$0.value.isEmpty }
            .map(\.key.chunk)
            .min() ?? 0
    }

    private func hasWaiters(_ segment: Int) -> Bool {
        waiters.contains { $0.key.segment == segment && !$0.value.isEmpty }
    }

    private func isCached(_ segment: Int) -> Bool {
        cache[AV1ChunkID(segment: segment, chunk: plan.chunkCount(of: segment) - 1)] != nil
    }

    /// Keeps the chunks nearest the one just made; AVPlayer re-asks for
    /// recent ones after a stall, rarely for anything far behind.
    private func store(_ data: Data, at id: AV1ChunkID) {
        cache[id] = data
        while cache.count > Self.cacheLimit {
            let distance: (AV1ChunkID) -> Int = { abs($0.segment - id.segment) }
            guard let farthest = cache.keys.max(by: { distance($0) < distance($1) }) else {
                break
            }
            cache.removeValue(forKey: farthest)
        }
    }
}
