import Foundation

/// Transcoded chunks, kept within a byte budget. Over it, what lies behind
/// the playhead goes first (oldest first), then what lies farthest ahead.
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

    mutating func store(_ data: Data, at id: AV1ChunkID, playhead: Int) {
        bytes += data.count - (entries[id]?.count ?? 0)
        entries[id] = data
        while bytes > limit, let victim = victim(sparing: id, playhead: playhead) {
            bytes -= entries.removeValue(forKey: victim)?.count ?? 0
        }
    }

    private func victim(sparing id: AV1ChunkID, playhead: Int) -> AV1ChunkID? {
        let others = entries.keys.filter { $0 != id }
        if let behind = others.filter({ $0.segment < playhead }).min(by: Self.precedes) {
            return behind
        }
        return others.max(by: Self.precedes)
    }

    subscript(id: AV1ChunkID) -> Data? {
        entries[id]
    }
}
