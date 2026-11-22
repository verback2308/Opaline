import CoreMedia
import Foundation
import VideoToolbox

/// One encoded frame, as length-prefixed NAL units ready for an `mdat`.
struct EncodedSample {
    let data: Data
    let timestamp: Int64
    let isSync: Bool
}

/// The SPS and PPS the `avcC` of the init segment carries.
struct H264ParameterSets {
    let sps: Data
    let pps: Data
}

/// The hardware H.264 encoder, used one segment at a time: every segment
/// opens on a forced key frame so AVPlayer can start or seek into any of
/// them, and frames are never reordered, so decode and presentation times
/// stay the source's.
final class H264SegmentEncoder {
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var output: [EncodedSample] = []
    /// What VideoToolbox is told each frame's time is. It insists on
    /// increasing presentation times for the life of the session, and one
    /// session serves segments in whatever order playback and seeks ask for
    /// them — so it runs on its own clock, stepping by each frame's real
    /// duration (rate control budgets bits per second of that clock) and by
    /// one nominal frame across any jump. Samples keep their source time.
    private var clock: EncoderClock
    private(set) var parameterSets: H264ParameterSets?

    init?(width: Int, height: Int, bitrate: Int, fps: Int) {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            return nil
        }
        session = created
        clock = EncoderClock(fps: fps)
        configure(bitrate: bitrate, fps: fps)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private static func isSync(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool
        return notSync != true
    }

    private static func parameterSets(_ format: CMFormatDescription) -> H264ParameterSets? {
        guard let sps = parameterSet(format, index: 0),
              let pps = parameterSet(format, index: 1) else {
            return nil
        }
        return H264ParameterSets(sps: sps, pps: pps)
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pointer else {
            return nil
        }
        return Data(bytes: pointer, count: size)
    }

    /// Submits one frame. The first frame of a segment must be a key frame.
    func encode(_ frame: DecodedFrame, timescale: Int32, keyFrame: Bool) {
        let tick = clock.advance(to: frame.timestamp, timescale: timescale)
        let time = CMTime(value: tick, timescale: timescale)
        let sourceTime = frame.timestamp
        let options = keyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: options,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample else {
                AppLog.hls("av1: encoder dropped a frame (\(status))")
                return
            }
            self?.collect(sample, sourceTime: sourceTime)
        }
    }

    /// Waits for every submitted frame and hands them back, in submission
    /// order — frames are never reordered.
    func finishSegment() -> [EncodedSample] {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock()
        defer {
            output = []
            lock.unlock()
        }
        return output
    }

    private func configure(bitrate: Int, fps: Int) {
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 100_000
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
    }

    private func collect(_ sample: CMSampleBuffer, sourceTime: Int64) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            return
        }
        var data = Data(count: CMBlockBufferGetDataLength(block))
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
        }
        let encoded = EncodedSample(data: data, timestamp: sourceTime, isSync: Self.isSync(sample))
        lock.lock()
        output.append(encoded)
        if parameterSets == nil {
            parameterSets = CMSampleBufferGetFormatDescription(sample).flatMap(Self.parameterSets)
        }
        lock.unlock()
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }
}

/// A presentation clock that only moves forward (see `H264SegmentEncoder`).
private struct EncoderClock {
    let fps: Int
    private var now: Int64 = 0
    private var lastSource: Int64?

    init(fps: Int) {
        self.fps = max(1, fps)
    }

    mutating func advance(to source: Int64, timescale: Int32) -> Int64 {
        let nominal = max(1, Int64(timescale) / Int64(fps))
        let step = lastSource.map { source - $0 } ?? nominal
        // A jump — a new segment out of order, a seek — counts as one frame.
        now += step > 0 && step < Int64(timescale) ? step : nominal
        lastSource = source
        return now
    }
}
