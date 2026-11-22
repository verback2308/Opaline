import Foundation

/// Transcoded chunks, kept within a byte budget. Over it, what the player
/// has already been given goes first (oldest first) — the lookahead is
/// costly to make again — and only then what lies farthest ahead.
struct AV1ChunkCache {
    let limit: Int
    private var entries: [AV1ChunkID: Data] = [:]
    private var bytes = 0

    init(limit: Int) {
        self.limit = limit
    }

    private static func precedes(_ lhs: AV1ChunkID, _ rhs: AV1ChunkID) -> Bool {
        (lhs.segment, lhs.chunk) < (rhs.segment, rhs.chunk)
    }

    mutating func store(_ data: Data, at id: AV1ChunkID, playhead: AV1ChunkID) {
        bytes += data.count - (entries[id]?.count ?? 0)
        entries[id] = data
        while bytes > limit, let victim = victim(sparing: id, playhead: playhead) {
            bytes -= entries.removeValue(forKey: victim)?.count ?? 0
        }
    }

    private func victim(sparing id: AV1ChunkID, playhead: AV1ChunkID) -> AV1ChunkID? {
        let others = entries.keys.filter { $0 != id }
        if let behind = others.filter({ Self.precedes($0, playhead) }).min(by: Self.precedes) {
            return behind
        }
        return others.max(by: Self.precedes)
    }

    /// Bytes held for chunks after `id`, up to segment `last`: what the
    /// lookahead made — not chunks left over from before a seek back.
    func bytes(after id: AV1ChunkID, through last: Int) -> Int {
        entries
            .filter { Self.precedes(id, $0.key) && $0.key.segment <= last }
            .reduce(0) { $0 + $1.value.count }
    }

    subscript(id: AV1ChunkID) -> Data? {
        entries[id]
    }
}
