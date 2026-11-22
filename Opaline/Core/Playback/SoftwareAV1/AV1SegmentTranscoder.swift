import Foundation

/// Timing of one transcoded segment, for logs and the stats overlay.
struct TranscodeStats {
    let frames: Int
    let seconds: Double

    var framesPerSecond: Double {
        seconds > 0 ? Double(frames) / seconds : 0
    }
}

/// Turns AV1 media segments into H.264 ones: dav1d decodes in software, the
/// hardware encoder re-encodes. Not thread-safe — one segment at a time.
final class AV1SegmentTranscoder {
    private let track: AV1TrackInfo
    private let decoder: AV1Decoder
    private let encoder: H264SegmentEncoder
    private let writer: H264FragmentWriter

    /// The RFC 6381 name of what the encoder actually produces — profile,
    /// constraints and level from its SPS. AVPlayer refuses a variant whose
    /// declared CODECS differ from the stream (-16170).
    var codecs: String {
        let sps = writer.parameterSets.sps
        let bytes = (1...3).map { String(format: "%02x", sps.mp4UInt8(at: $0)) }
        return "avc1." + bytes.joined()
    }

    /// Fails when the device can neither decode nor encode at this size.
    init?(initSegment: Data, fps: Int) {
        guard let track = FragmentedMP4Reader.trackInfo(fromInit: initSegment),
              let decoder = AV1Decoder(
                  width: track.width,
                  height: track.height,
                  threads: ProcessInfo.processInfo.activeProcessorCount
              ),
              let encoder = H264SegmentEncoder(
                  width: track.width,
                  height: track.height,
                  bitrate: Self.bitrate(height: track.height, fps: fps),
                  fps: fps
              ),
              let parameterSets = Self.prime(encoder, track: track) else {
            return nil
        }
        self.track = track
        self.decoder = decoder
        self.encoder = encoder
        writer = H264FragmentWriter(
            width: track.width,
            height: track.height,
            timescale: track.timescale,
            parameterSets: parameterSets
        )
    }

    /// Roughly two to three times what YouTube spends on AV1 at the same
    /// size — H.264 needs that to look the same. An average: single segments
    /// run up to twice it, which is what playlists should declare.
    static func bitrate(height: Int, fps: Int) -> Int {
        let base = height >= 2_000 ? 30_000_000 : height >= 1_400 ? 16_000_000 : 8_000_000
        return fps > 30 ? base * 3 / 2 : base
    }

    /// Encodes one black frame so the SPS/PPS exist before any segment does:
    /// AVPlayer asks for the init segment first.
    private static func prime(
        _ encoder: H264SegmentEncoder,
        track: AV1TrackInfo
    ) -> H264ParameterSets? {
        guard let pool = NV12PixelPool(width: track.width, height: track.height),
              let frame = pool.blankFrame() else {
            return nil
        }
        encoder.encode(frame, timescale: Int32(track.timescale), keyFrame: true)
        _ = encoder.finishSegment()
        return encoder.parameterSets
    }

    func initSegment() -> Data {
        writer.initSegment()
    }

    /// One source segment in, its chunks out, each handed to `onChunk` the
    /// moment it is encoded. Chunks before `plan.first` are decoded — they
    /// lead up to it — but never encoded. Returns nil when the segment could
    /// not be decoded; chunks already delivered stay delivered.
    func transcode(
        _ segment: Data,
        index: Int,
        plan: ChunkRequest,
        onChunk: (Int, Data) -> Void
    ) -> TranscodeStats? {
        let started = CFAbsoluteTimeGetCurrent()
        let samples = FragmentedMP4Reader.samples(fromSegment: segment)
        guard !samples.isEmpty else {
            return nil
        }
        decoder.reset()
        var cutter = ChunkCutter(samples: samples, chunks: plan.count)
        cutter.current = min(plan.first, plan.count - 1)
        decoder.skipBefore = cutter.start(of: cutter.current)
        let timescale = Int32(track.timescale)
        let encode: (DecodedFrame) -> Void = { frame in
            let chunk = cutter.chunk(of: frame.timestamp)
            if chunk != cutter.current {
                self.flush(&cutter, index: index, onChunk: onChunk)
                cutter.current = chunk
            }
            self.encoder.encode(frame, timescale: timescale, keyFrame: cutter.frames == 0)
            cutter.frames += 1
            cutter.total += 1
        }
        for sample in samples {
            let time = Int64(sample.decodeTime)
            guard decoder.decode(sample.data, timestamp: time, sink: encode) else {
                return nil
            }
        }
        decoder.drain(sink: encode)
        flush(&cutter, index: index, onChunk: onChunk)
        return TranscodeStats(frames: cutter.total, seconds: CFAbsoluteTimeGetCurrent() - started)
    }

    /// Closes the chunk being encoded and hands it over.
    private func flush(_ cutter: inout ChunkCutter, index: Int, onChunk: (Int, Data) -> Void) {
        guard cutter.frames > 0 else {
            return
        }
        let encoded = encoder.finishSegment()
        let lastDuration = encoded.last.map { cutter.duration(at: $0.timestamp) } ?? 0
        let fragment = writer.mediaSegment(
            sequence: UInt32(index * 64 + cutter.current + 1),
            samples: encoded,
            lastDuration: lastDuration
        )
        onChunk(cutter.current, fragment)
        cutter.frames = 0
    }
}

/// Splits a segment's frames into chunks of equal time.
private struct ChunkCutter {
    let boundaries: [Int64]
    let durations: [Int64: UInt32]
    var current = 0
    var frames = 0
    var total = 0

    init(samples: [MediaSample], chunks: Int) {
        let first = Int64(samples.first?.decodeTime ?? 0)
        let span = samples.reduce(Int64(0)) { $0 + Int64($1.duration) }
        let count = Int64(max(1, chunks))
        boundaries = (1..<count).map { first + span * $0 / count }
        durations = Dictionary(samples.map { (Int64($0.decodeTime), $0.duration) }) { kept, _ in
            kept
        }
    }

    /// Where a chunk begins; the first one has no lower bound.
    func start(of chunk: Int) -> Int64 {
        chunk > 0 && chunk <= boundaries.count ? boundaries[chunk - 1] : Int64.min
    }

    func chunk(of timestamp: Int64) -> Int {
        boundaries.filter { $0 <= timestamp }.count
    }

    func duration(at timestamp: Int64) -> UInt32 {
        durations[timestamp] ?? 0
    }
}

/// Which chunks of a segment to produce: all of them from `first` on.
struct ChunkRequest {
    let count: Int
    let first: Int
}
