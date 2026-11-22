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

    /// One media segment in, one out; nil when it could not be decoded.
    func transcode(_ segment: Data, sequence: UInt32) -> (Data, TranscodeStats)? {
        let started = CFAbsoluteTimeGetCurrent()
        let samples = FragmentedMP4Reader.samples(fromSegment: segment)
        guard !samples.isEmpty else {
            return nil
        }
        decoder.reset()
        let timescale = Int32(track.timescale)
        var frames = 0
        let encode: (DecodedFrame) -> Void = { frame in
            self.encoder.encode(frame, timescale: timescale, keyFrame: frames == 0)
            frames += 1
        }
        for sample in samples {
            let time = Int64(sample.decodeTime)
            guard decoder.decode(sample.data, timestamp: time, sink: encode) else {
                return nil
            }
        }
        decoder.drain(sink: encode)
        let encoded = finishEncoding(since: started)
        let output = writer.mediaSegment(
            sequence: sequence,
            samples: encoded,
            lastDuration: samples.last?.duration ?? 0
        )
        let stats = TranscodeStats(frames: frames, seconds: CFAbsoluteTimeGetCurrent() - started)
        return (output, stats)
    }

    /// Waits for the encoder and logs where the segment's time went.
    private func finishEncoding(since started: CFAbsoluteTime) -> [EncodedSample] {
        let decoded = CFAbsoluteTimeGetCurrent()
        let encoded = encoder.finishSegment()
        AppLog.hls(String(
            format: "av1 split: decode+submit %.2fs, encoder tail %.2fs",
            decoded - started,
            CFAbsoluteTimeGetCurrent() - decoded
        ))
        return encoded
    }
}
