import Foundation

/// One piece of a source segment, addressed as `<segment>.<chunk>`.
struct AV1ChunkID: Hashable {
    let segment: Int
    let chunk: Int

    var name: String {
        "\(segment).\(chunk)"
    }

    init(segment: Int, chunk: Int) {
        self.segment = segment
        self.chunk = chunk
    }

    /// Parses `"<segment>.<chunk>"`.
    init?(name: String) {
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else {
            return nil
        }
        self.init(segment: parts[0], chunk: parts[1])
    }
}

/// How the transcoded track is cut for the player. YouTube's segments run
/// 5–10 s, and a whole one has to be decoded before AVPlayer gets a byte of
/// it — at 1440p60 that kept it waiting ~6 s to start. Each segment is split
/// into ~2 s chunks instead, each opening on its own key frame, handed over
/// as soon as it is encoded.
struct AV1ChunkPlan {
    private static let targetSeconds = 2.0

    /// Chunk count per source segment.
    let counts: [Int]
    let durations: [Double]

    init(segments: [SidxSegment]) {
        durations = segments.map(\.duration)
        counts = durations.map { max(1, Int(($0 / Self.targetSeconds).rounded())) }
    }

    func chunkCount(of segment: Int) -> Int {
        counts.indices.contains(segment) ? counts[segment] : 1
    }

    /// The video media playlist, chunk by chunk, URIs relative to `base`.
    func playlist(base: String, startAt: Double?) -> String {
        let longest = zip(durations, counts).map { $0 / Double($1) }.max() ?? 2
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        lines.append("#EXT-X-TARGETDURATION:\(Int(ceil(longest)))")
        lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        if let startAt, startAt > 0 {
            lines.append(String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", startAt))
        }
        lines.append("#EXT-X-MAP:URI=\"\(base)/init\"")
        for (segment, count) in counts.enumerated() {
            let each = durations[segment] / Double(count)
            for chunk in 0..<count {
                lines.append(String(format: "#EXTINF:%.3f,", each))
                lines.append("\(base)/\(AV1ChunkID(segment: segment, chunk: chunk).name)")
            }
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
