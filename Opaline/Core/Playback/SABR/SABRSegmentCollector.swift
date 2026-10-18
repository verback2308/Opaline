import Foundation

/// The server's pacing, from `NextRequestPolicy`.
struct SABRPolicy {
    /// Field 4: hold off this long before the next request.
    var backoffMs = 0
    /// Field 7: carried by every later request.
    var playbackCookie: Data?
}

/// Reads one response and keeps the one segment it was asked for.
///
/// The media header for the requested format and sequence claims the response: its
/// `MEDIA` parts are collected and everything else the server sends — the
/// other track, the segments after this one — is dropped on the floor. That is
/// how googlevideo's player adapter does it, and it is what makes a request
/// mean one segment rather than "some of the stream, from around here".
final class SABRSegmentCollector {
    let request: SABRSegmentRequest
    private let reader = UMPReader()
    private var headers: [Int: MediaHeader] = [:]
    private var wantedHeaderId: Int?
    private var chunks: [Data] = []
    private(set) var received = 0
    private(set) var isDone = false
    private(set) var failure: Error?
    private(set) var policy: SABRPolicy?
    /// What was collected, for the next request to acknowledge.
    private(set) var deliveredRange: SABRBufferedRange?
    /// Every part type the response carried, in order — the only way to see
    /// what the server answered with when it answers without media.
    private(set) var seenTypes: [Int] = []

    var label: String {
        let kind = request.isInit ? "init" : "\(request.sequence)"
        return "\(request.format.itag)/\(kind)@\(request.timeMs)ms"
    }

    /// The collected bytes, sliced to the init range when one was asked for.
    ///
    /// Not gated on `MEDIA_END`: that part is how the end of a segment is
    /// normally known, but a response that simply stops after delivering one
    /// has still delivered it.
    var segment: Data? {
        guard !chunks.isEmpty else {
            return nil
        }
        var data = chunks.count == 1 ? chunks[0] : chunks.reduce(into: Data()) { $0 += $1 }
        if let length = request.initRange {
            data = data.prefix(length)
        }
        return data
    }

    /// What a response without media carried instead, for the log.
    var noMediaLine: String {
        "\(label): no media in \(received)B, parts \(seenTypes)"
    }

    init(request: SABRSegmentRequest) {
        self.request = request
    }

    /// Whether a served header is the track that was asked for. A request
    /// without `xtags` takes whatever comes — single-audio videos name no
    /// track at all.
    private static func sameTrack(_ served: String?, _ wanted: String?) -> Bool {
        guard let wanted, !wanted.isEmpty else {
            return true
        }
        guard let served, !served.isEmpty else {
            return true
        }
        return served == wanted
    }

    func append(_ chunk: Data) {
        received += chunk.count
        reader.append(chunk)
        for part in reader.readParts() where !isDone {
            handle(part)
        }
    }

    private func handle(_ part: UMPPart) {
        seenTypes.append(part.type)
        switch UMPPartType(rawValue: part.type) {
        case .mediaHeader:
            noteHeader(part.payload)
        case .media:
            collect(part.payload)
        case .mediaEnd:
            finishIfWanted(part.payload)
        case .nextRequestPolicy:
            notePolicy(Protobuf.parse(part.payload))
        default:
            handleDirective(part)
        }
    }

    /// The parts that say something about the session rather than the media.
    private func handleDirective(_ part: UMPPart) {
        switch UMPPartType(rawValue: part.type) {
        case .streamProtectionStatus:
            // 1 = OK, 2 = attestation pending, 3 = attestation required.
            let status = Protobuf.parse(part.payload).number(1) ?? 0
            if status >= 2 {
                AppLog.hls("sabr stream protection status: \(status)")
            }
        case .sabrError:
            let fields = Protobuf.parse(part.payload)
            AppLog.hls("sabr error: fields=\(fields.keys.sorted())")
            failure = SABRError.server("server rejected the request")
            isDone = true
        case .reloadPlayerResponse:
            failure = SABRError.server("player response expired")
            isDone = true
        default:
            break
        }
    }

    /// A response can begin with the preceding segment when the requested
    /// millisecond position rounds below a segment boundary. Keep reading until
    /// the requested sequence arrives; serving the earlier bytes at the new HLS
    /// URL repeats timestamps and freezes video while audio continues.
    private func noteHeader(_ payload: Data) {
        let fields = Protobuf.parse(payload)
        guard let header = MediaHeader(payload) else {
            return
        }
        let id = fields.number(1) ?? 0
        headers[id] = header
        // The itag alone does not name a track: every dub of a video carries
        // the same one, and only `xtags` tells them apart. A response can hold
        // several of them, so claiming the first matching itag is how a
        // request for a dub ends up playing the original.
        guard wantedHeaderId == nil, header.itag == request.format.itag,
              header.isInit == request.isInit,
              Self.sameTrack(header.xtags, request.format.xtags) else {
            return
        }
        guard request.isInit || header.sequence == request.sequence else {
            AppLog.hls("sabr \(label): skipping sequence \(header.sequence) at \(header.startMs)ms")
            return
        }
        wantedHeaderId = id
        AppLog.hls(
            "sabr \(label) served sequence \(header.sequence) at \(header.startMs)ms"
                + " itag \(header.itag) xtags \(header.xtags ?? "-")"
        )
        // An init segment is not a position in the stream, so it must not be
        // acknowledged as one: a buffered range starting at 0 alongside a
        // player time in the middle of the video is a contradiction, and the
        // server answers it with start policies and no media. googlevideo's
        // own adapter builds ranges from media headers only, never init ones.
        guard !request.isInit else {
            return
        }
        deliveredRange = SABRBufferedRange(
            format: request.format,
            startMs: header.startMs,
            durationMs: header.durationMs,
            startSequence: header.sequence,
            endSequence: header.sequence,
            timescale: header.timescale
        )
    }

    /// A `MEDIA` payload leads with the varint id of the header it belongs to.
    private func collect(_ payload: Data) {
        guard let (id, offset) = Protobuf.readVarint(payload, 0),
              Int(id) == wantedHeaderId, offset < payload.count else {
            return
        }
        chunks.append(payload.suffix(from: payload.startIndex + offset))
    }

    private func finishIfWanted(_ payload: Data) {
        guard let (id, _) = Protobuf.readVarint(payload, 0), Int(id) == wantedHeaderId else {
            return
        }
        isDone = true
    }

    private func notePolicy(_ fields: [Int: [Protobuf.Value]]) {
        policy = SABRPolicy(backoffMs: fields.number(4) ?? 0, playbackCookie: fields.data(7))
    }
}
