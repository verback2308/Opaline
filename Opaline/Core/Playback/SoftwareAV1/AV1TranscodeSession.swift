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
    /// Chunks are fetched once in normal playback; the cache only bridges
    /// the gap between transcoding ahead and being asked. Bounded in bytes —
    /// a 1440p60 chunk runs to several MB, and these devices have 2 GB.
    private static let cacheBytes = 48 << 20

    let plan: AV1ChunkPlan
    private let fetchSource: SourceFetch
    private let fps: Int
    /// State only — every hop here is short, so cache hits never wait.
    private let queue = DispatchQueue(label: "com.ytvlite.av1-session", qos: .userInitiated)
    /// The transcodes themselves, one at a time.
    private let work = DispatchQueue(label: "com.ytvlite.av1-transcode", qos: .userInitiated)
    private var transcoder: AV1SegmentTranscoder?
    private var initSource: Data?
    private var initData: Data?
    private var initWaiters: [Completion] = []
    private var cannotTranscode = false
    private var cache = ChunkCache(limit: AV1TranscodeSession.cacheBytes)
    private var waiters: [AV1ChunkID: [Completion]] = [:]
    private var sources: [Int: Data] = [:]
    private var fetching = Set<Int>()
    /// The segment on the work queue right now, and its first chunk made.
    private var transcoding: AV1ChunkID?
    private var transcodingCancel: CancelFlag?
    /// Segments worth working on: the one last asked for and the lookahead.
    private var window = 0...AV1TranscodeSession.lookahead

    /// `initSource`, when the delivery already holds the init segment, saves
    /// fetching it again before the first playlist can be answered.
    init(
        plan: AV1ChunkPlan,
        fps: Int,
        initSource: Data? = nil,
        fetchSource: @escaping SourceFetch
    ) {
        self.plan = plan
        self.fps = fps
        self.initSource = initSource
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
                self.moveWindow(to: id.segment)
                self.request(id, completion: completion)
                for ahead in 1...Self.lookahead {
                    self.prepare(id.segment + ahead)
                }
            }
        }
    }

    // MARK: - Queue-confined

    /// Runs `body` once the transcoder exists, building it from the source
    /// init segment on first use. A failed fetch is retried on the next
    /// call; a stream the transcoder cannot take is given up on for good.
    private func withTranscoder(_ body: @escaping (AV1SegmentTranscoder?) -> Void) {
        if transcoder != nil || cannotTranscode {
            body(transcoder)
            return
        }
        initWaiters.append { _ in body(self.transcoder) }
        guard initWaiters.count == 1 else {
            return
        }
        if let seeded = initSource {
            initSource = nil
            queue.async { self.finishInit(seeded) }
            return
        }
        fetchSource(nil) { data in
            self.queue.async { self.finishInit(data) }
        }
    }

    private func finishInit(_ source: Data?) {
        if let source {
            if let built = AV1SegmentTranscoder(initSegment: source, fps: fps) {
                transcoder = built
                initData = built.initSegment()
            } else {
                AppLog.hls("av1: this stream cannot be transcoded here")
                cannotTranscode = true
                AV1Support.markSoftwareUnavailable()
            }
        }
        let pending = initWaiters
        initWaiters = []
        pending.forEach { $0(initData) }
    }

    /// Follows the playhead: sources downloaded for where it was — before a
    /// seek — are dropped rather than transcoded ahead of where it is now.
    private func moveWindow(to segment: Int) {
        window = segment...(segment + Self.lookahead)
        sources = sources.filter { window.contains($0.key) || hasWaiters($0.key) }
        if let running = transcoding?.segment, !window.contains(running), !hasWaiters(running) {
            AppLog.hls("av1: dropping segment \(running), playback moved to \(segment)")
            transcodingCancel?.raise()
        }
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
              sources[segment] == nil, !fetching.contains(segment),
              transcoding?.segment != segment,
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
        guard window.contains(segment) || hasWaiters(segment) else {
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
        let request = ChunkRequest(
            count: plan.chunkCount(of: segment),
            first: firstWanted(in: segment)
        )
        transcoding = AV1ChunkID(segment: segment, chunk: request.first)
        transcodingCancel = request.cancel
        work.async {
            let onChunk: (Int, Data) -> Void = { chunk, data in
                let id = AV1ChunkID(segment: segment, chunk: chunk)
                self.queue.async { self.deliver(id, data) }
            }
            let stats = self.transcoder?.transcode(
                source,
                index: segment,
                plan: request,
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
        let pending = ready.union(fetching).filter(window.contains)
        guard let lowest = pending.min(), ready.contains(lowest) else {
            return nil
        }
        return lowest
    }

    private func deliver(_ id: AV1ChunkID, _ data: Data) {
        cache.store(data, at: id)
        let pending = waiters.removeValue(forKey: id) ?? []
        pending.forEach { $0(data) }
    }

    private func finishSegment(_ segment: Int, stats: TranscodeStats?) {
        let first = transcoding?.chunk ?? 0
        transcoding = nil
        transcodingCancel = nil
        if let stats {
            let timing = String(format: "%.2fs (%.0f fps)", stats.seconds, stats.framesPerSecond)
            AppLog.hls("av1 seg \(segment): \(stats.frames) frames in \(timing)")
        }
        // A chunk before the first one this pass made was asked for while it
        // ran (a seek back within the segment): go round again for it.
        // Anything else still waiting was not produced — answer it.
        if waiters.keys.contains(where: { $0.segment == segment && $0.chunk < first }) {
            prepare(segment)
        } else {
            failWaiters(of: segment)
        }
        pump()
    }
}

// MARK: - Bookkeeping

private extension AV1TranscodeSession {
    func failWaiters(of segment: Int) {
        for id in waiters.keys where id.segment == segment {
            waiters.removeValue(forKey: id)?.forEach { $0(nil) }
        }
    }

    /// The earliest chunk anyone is waiting for — a start or seek into the
    /// middle of a segment skips encoding what lies before it. A segment
    /// nobody waits on yet (lookahead) is made whole.
    func firstWanted(in segment: Int) -> Int {
        waiters.filter { $0.key.segment == segment && !$0.value.isEmpty }
            .map(\.key.chunk)
            .min() ?? 0
    }

    func hasWaiters(_ segment: Int) -> Bool {
        waiters.contains { $0.key.segment == segment && !$0.value.isEmpty }
    }

    func isCached(_ segment: Int) -> Bool {
        cache[AV1ChunkID(segment: segment, chunk: plan.chunkCount(of: segment) - 1)] != nil
    }
}

/// Transcoded chunks, kept within a byte budget; the ones farthest from the
/// newest go first.
private struct ChunkCache {
    let limit: Int
    private var entries: [AV1ChunkID: Data] = [:]
    private var bytes = 0

    init(limit: Int) {
        self.limit = limit
    }

    mutating func store(_ data: Data, at id: AV1ChunkID) {
        bytes += data.count - (entries[id]?.count ?? 0)
        entries[id] = data
        while bytes > limit, let farthest = farthest(from: id) {
            bytes -= entries.removeValue(forKey: farthest)?.count ?? 0
        }
    }

    private func farthest(from id: AV1ChunkID) -> AV1ChunkID? {
        let distance: (AV1ChunkID) -> Int = { abs($0.segment - id.segment) }
        return entries.keys.filter { $0 != id }.max { distance($0) < distance($1) }
    }

    subscript(id: AV1ChunkID) -> Data? {
        entries[id]
    }
}
