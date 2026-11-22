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
        let time = CMTime(value: frame.timestamp, timescale: timescale)
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
                return
            }
            self?.collect(sample, timescale: timescale)
        }
    }

    /// Waits for every submitted frame and hands them back in order.
    func finishSegment() -> [EncodedSample] {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock()
        defer {
            output = []
            lock.unlock()
        }
        return output.sorted { $0.timestamp < $1.timestamp }
    }

    private func configure(bitrate: Int, fps: Int) {
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: false,
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

    private func collect(_ sample: CMSampleBuffer, timescale: Int32) {
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
        let time = CMSampleBufferGetPresentationTimeStamp(sample).convertScale(
            timescale,
            method: .roundHalfAwayFromZero
        )
        let encoded = EncodedSample(data: data, timestamp: time.value, isSync: Self.isSync(sample))
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
