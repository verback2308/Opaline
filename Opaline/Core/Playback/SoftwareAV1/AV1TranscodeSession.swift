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
    /// Bridges transcoding ahead and being asked; a 1440p60 chunk runs to
    /// MBs on 2 GB devices. The lookahead keeps to half (`lookaheadFull`).
    private static let cacheBytes = 64 << 20

    let plan: AV1ChunkPlan
    private let fetchSource: SourceFetch
    private let fps: Int
    private let height: Int
    private let queue = DispatchQueue(label: "com.ytvlite.av1-session", qos: .userInitiated)
    private let work = DispatchQueue(label: "com.ytvlite.av1-transcode", qos: .userInitiated)
    private var transcoder: AV1SegmentTranscoder?
    private var initSource: Data?
    private var initData: Data?
    private var initWaiters: [Completion] = []
    private var cannotTranscode = false
    private var cache = AV1ChunkCache(limit: AV1TranscodeSession.cacheBytes)
    private var waiters: [AV1ChunkID: [Completion]] = [:]
    private var sources: [Int: Data] = [:]
    private var fetching = Set<Int>()
    /// The segment on the work queue right now, and its first chunk made.
    private var transcoding: AV1ChunkID?
    private var transcodingCancel: CancelFlag?
    /// Segments worth working on: the one last asked for and the lookahead.
    private var window = 0...AV1TranscodeSession.lookahead
    /// The chunk the player asked for last — what the cache keeps around.
    private var playhead = AV1ChunkID(segment: 0, chunk: 0)
    private var closed = false
    private var retried = Set<Int>()

    /// `initSource`, when the delivery already holds the init segment, saves
    /// fetching it again before the first playlist can be answered.
    init(
        plan: AV1ChunkPlan,
        format: (height: Int, fps: Int),
        initSource: Data? = nil,
        fetchSource: @escaping SourceFetch
    ) {
        self.plan = plan
        self.fps = format.fps
        self.height = format.height
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
                guard transcoder != nil, !self.closed else {
                    completion(nil)
                    return
                }
                self.playhead = id
                // A cache hit behind the window (the player re-reading
                // what it already played) must not cancel the lookahead.
                if self.cache[id] == nil || id.segment > self.window.lowerBound {
                    self.moveWindow(to: id.segment)
                }
                self.request(id, completion: completion)
                for ahead in 1...Self.lookahead {
                    self.prepare(id.segment + ahead)
                }
                // The segment may already be downloaded and held back
                // behind a lower one that no longer matters.
                self.pump()
            }
        }
    }

    // MARK: - Queue-confined

    /// Runs `body` once the transcoder exists, built from the init segment on
    /// first use. A failed fetch is retried; an unusable stream is not.
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
                AV1Support.markSoftwareUnavailable(height: height, fps: fps)
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
        guard !closed, plan.counts.indices.contains(segment),
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
        if data == nil {
            failWaiters(of: segment)
        } else if !closed, window.contains(segment) || hasWaiters(segment) {
            sources[segment] = data
        }
        // Whatever happened to it, a segment held back behind it may be next.
        pump()
    }

    /// Starts the next transcode on the work queue: a segment the player is
    /// waiting on first, otherwise strictly in order — when the next one in
    /// line is still downloading, it waits for it rather than skipping ahead.
    private func pump() {
        guard !closed, transcoding == nil,
              let segment = nextSegment(), let source = sources[segment] else {
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
        guard let lowest = pending.min(), ready.contains(lowest),
              lowest == playhead.segment || !lookaheadFull else {
            return nil
        }
        return lowest
    }

    private func deliver(_ id: AV1ChunkID, _ data: Data) {
        cache.store(data, at: id, playhead: playhead)
        retried.remove(id.segment)
        let pending = waiters.removeValue(forKey: id) ?? []
        pending.forEach { $0(data) }
    }

    private func finishSegment(_ segment: Int, stats: TranscodeStats?) {
        let first = transcoding?.chunk ?? 0
        let cancelled = transcodingCancel?.isRaised ?? false
        transcoding = nil
        transcodingCancel = nil
        if let stats {
            let timing = String(format: "%.2fs (%.0f fps)", stats.seconds, stats.framesPerSecond)
            AppLog.hls("av1 seg \(segment): \(stats.frames) frames in \(timing)")
        }
        // Go round again for a seek back before this pass's first chunk, a dropped
        // pass wanted again, or once for frames lost (a lock). Else answer.
        let missed = waiters.keys.contains { $0.segment == segment && $0.chunk < first }
        let retry = !missed && !cancelled && hasWaiters(segment) && retried.insert(segment).inserted
        if missed || retry || (cancelled && hasWaiters(segment)) {
            prepare(segment)
        } else {
            failWaiters(of: segment)
        }
        pump()
    }
}

// MARK: - Teardown

extension AV1TranscodeSession {
    /// Stops all work for good once playback has moved off this stream:
    /// a transcode left running would keep the CPU busy for nobody.
    func close() {
        queue.async {
            self.closed = true
            self.transcodingCancel?.raise()
            self.sources = [:]
            let pending = self.waiters.values.flatMap { $0 }
            self.waiters = [:]
            pending.forEach { $0(nil) }
        }
    }
}

// MARK: - Bookkeeping

private extension AV1TranscodeSession {
    /// The lookahead stops while what is cached ahead of the playhead fills
    /// half the cache: a segment evicted before it is played costs a stall.
    var lookaheadFull: Bool {
        cache.bytes(after: playhead, through: window.upperBound) >= Self.cacheBytes / 2
    }

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
