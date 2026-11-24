import UIKit

struct WatchProgress {
    let fraction: Double

    var shouldShow: Bool {
        fraction > 0.03
    }
}

/// Stores per-video watch progress. Written both by this device
/// while playing (`setLocalFraction`) and by the server —
/// WatchProgressSyncService plus inline extraction from
/// browse/feed responses.
///
/// The server lags a local view by seconds to minutes (the
/// watchtime pings have to land and propagate), so a fresh local
/// entry wins over anything the server says for `serverGrace`;
/// after that the server is the better truth, because it also
/// carries views from other devices — where it has one. A video
/// the server lists no position for keeps the one this device
/// recorded: YouTube does not always store a resume point.
final class WatchProgressStore {
    static let shared = WatchProgressStore()

    private let fractionKey = "WatchProgressStore.fractions"
    private let localTimesKey = "WatchProgressStore.localTimes"
    private let localIdsKey = "WatchProgressStore.localIds"
    /// Set by the player for a video that plays as part of a queue: those
    /// open at their start, whoever asks. Video sources read this store
    /// directly and build the stream at the saved playhead, so the rule has
    /// to live here rather than in the watch screen — checked there, the
    /// source resumed anyway.
    var suppressResume = false
    private let maxEntries = 200
    private let persistDebounceInterval: TimeInterval = 5
    /// How long a locally recorded position outranks the server.
    private let serverGrace: TimeInterval = 5 * 60

    /// Guards `fractions` and `localTimes`. Never call UserDefaults
    /// or NotificationCenter while holding it.
    private let lock = NSLock()
    private var fractions: [String: Double] = [:]
    /// When this device last recorded a position, per video id
    /// (epoch seconds). Only entries younger than `serverGrace`
    /// matter; older ones are dropped on write.
    private var localTimes: [String: Double] = [:]
    /// Videos whose stored position this device recorded, kept
    /// through a history sync that has none for them.
    private var localIds = Set<String>()

    /// Serial: all UserDefaults writes and pending-write bookkeeping
    /// happen here, off the lock.
    private let persistQueue = DispatchQueue(
        label: "com.ytvlite.watch-progress.persist"
    )
    /// Only touched from `persistQueue`.
    private var pendingWork: DispatchWorkItem?
    /// A timecode carried by a link (`youtu.be/ID?t=87`). It outranks stored
    /// progress for that one video, so every reader of `resumeSeconds` — the
    /// player shell and the sources that open a stream at the playhead —
    /// agrees on where the link asked to start. Dropped once this device
    /// records a position of its own for that video.
    private var linkStart: (videoId: String, seconds: Double)?

    init() {
        loadFractions()
        UserDefaults.standard.removeObject(
            forKey: "WatchProgressStore.v1"
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    /// Server-provided progress for a single video, extracted inline
    /// from a browse/feed response. Ignored while a local entry for
    /// the same video is still within the grace window.
    func setFraction(
        videoId: String,
        fraction: Double
    ) {
        lock.lock()
        if !isLocallyFreshLocked(videoId) {
            fractions[videoId] = fraction
            trimLocked()
        }
        lock.unlock()
        schedulePersist()
    }

    /// Progress observed on this device during playback. Always
    /// wins: nothing else knows the position better right now.
    func setLocalFraction(
        videoId: String,
        fraction: Double
    ) {
        lock.lock()
        if linkStart?.videoId == videoId {
            linkStart = nil
        }
        fractions[videoId] = fraction
        localTimes[videoId] = Date().timeIntervalSince1970
        localIds.insert(videoId)
        trimLocked()
        lock.unlock()
        schedulePersist()
    }

    /// Full replacement from a history sync — entries the server no
    /// longer knows about disappear, which is how a cleared history
    /// propagates. Locally fresh positions survive it.
    func setServerFractions(
        _ entries: [String: Double]
    ) {
        lock.lock()
        var merged = entries
        for (videoId, fraction) in fractions
            where isLocallyFreshLocked(videoId)
            || (entries[videoId] == nil && localIds.contains(videoId)) {
            merged[videoId] = fraction
        }
        fractions = merged
        localIds.formIntersection(merged.keys)
        trimLocked()
        lock.unlock()
        persistQueue.async {
            self.pendingWork?.cancel()
            self.pendingWork = nil
            self.writeToDefaults()
        }
    }

    func progress(
        forVideoId videoId: String
    ) -> WatchProgress? {
        lock.lock()
        let frac = fractions[videoId]
        lock.unlock()
        guard let frac else {
            return nil
        }
        return WatchProgress(fraction: frac)
    }

    /// Where playback should pick this video up, or nil when it should start
    /// from the beginning (barely watched, or watched to the end). One place
    /// for the rule, because both the player shell and the sources building
    /// the stream have to agree on where "resume" is.
    func setLinkStart(seconds: Double, forVideoId videoId: String) {
        lock.lock()
        linkStart = (videoId, seconds)
        lock.unlock()
    }

    func resumeSeconds(
        forVideoId videoId: String,
        duration: Double?
    ) -> Double? {
        guard !suppressResume else {
            return nil
        }
        lock.lock()
        let link = linkStart
        lock.unlock()
        if let link, link.videoId == videoId {
            return link.seconds
        }
        guard let duration, duration > 0,
              let prog = progress(forVideoId: videoId),
              prog.shouldShow, prog.fraction < 0.97 else {
            return nil
        }
        return prog.fraction * duration
    }

    func clearAll() {
        lock.lock()
        fractions.removeAll()
        localTimes.removeAll()
        localIds.removeAll()
        lock.unlock()
        persistQueue.async {
            self.pendingWork?.cancel()
            self.pendingWork = nil
            UserDefaults.standard.removeObject(
                forKey: self.fractionKey
            )
            UserDefaults.standard.removeObject(
                forKey: self.localTimesKey
            )
            UserDefaults.standard.removeObject(
                forKey: self.localIdsKey
            )
        }
    }

    // MARK: - Local freshness

    /// Call with `lock` held.
    private func isLocallyFreshLocked(_ videoId: String) -> Bool {
        guard let at = localTimes[videoId] else {
            return false
        }
        return Date().timeIntervalSince1970 - at < serverGrace
    }

    /// Caps the table and drops local stamps that have aged out of
    /// the grace window. Call with `lock` held.
    private func trimLocked() {
        let cutoff = Date().timeIntervalSince1970 - serverGrace
        localTimes = localTimes.filter { $0.value >= cutoff }
        guard fractions.count > maxEntries else {
            return
        }
        let excess = fractions.count - maxEntries
        fractions.keys.prefix(excess).forEach {
            fractions.removeValue(forKey: $0)
            localIds.remove($0)
        }
    }
}

// MARK: - Persistence

extension WatchProgressStore {
    private func loadFractions() {
        let defaults = UserDefaults.standard
        if let raw = defaults.dictionary(
            forKey: fractionKey
        ) as? [String: Double] {
            fractions = raw
        }
        if let times = defaults.dictionary(
            forKey: localTimesKey
        ) as? [String: Double] {
            localTimes = times
        }
        if let ids = defaults.stringArray(forKey: localIdsKey) {
            localIds = Set(ids)
        }
    }

    /// Throttles UserDefaults writes to at most one per
    /// `persistDebounceInterval`. Safe to call from any thread.
    private func schedulePersist() {
        persistQueue.async {
            guard self.pendingWork == nil else {
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else {
                    return
                }
                self.pendingWork = nil
                self.writeToDefaults()
            }
            self.pendingWork = work
            self.persistQueue.asyncAfter(
                deadline: .now() + self.persistDebounceInterval,
                execute: work
            )
        }
    }

    /// Must run on `persistQueue`. Copies the dictionary under the
    /// lock, then writes outside it.
    private func writeToDefaults() {
        lock.lock()
        let snapshot = fractions
        let times = localTimes
        let ids = Array(localIds)
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: fractionKey)
        UserDefaults.standard.set(times, forKey: localTimesKey)
        UserDefaults.standard.set(ids, forKey: localIdsKey)
    }

    @objc
    private func appDidEnterBackground() {
        // Synchronous: the app can be suspended right after this
        // handler returns, so the flush must finish before that.
        persistQueue.sync {
            self.pendingWork?.cancel()
            self.pendingWork = nil
            self.writeToDefaults()
        }
    }
}
