import CoreVideo
import Dav1d
import Foundation

/// A decoded picture and the decode time of the sample it came from.
struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: Int64
}

/// dav1d behind a minimal push/pull interface. Pictures come out as NV12
/// `CVPixelBuffer`s, the layout VideoToolbox's encoder takes without a copy
/// of its own. Only 8-bit 4:2:0 is supported — what YouTube's SDR AV1 is.
final class AV1Decoder {
    /// Pictures before this time are decoded — later frames depend on
    /// them — but dropped without the conversion a kept one costs.
    var skipBefore = Int64.min
    private var context: OpaquePointer?
    private let pixelPool: NV12PixelPool

    init?(width: Int, height: Int, threads: Int) {
        var settings = Dav1dSettings()
        dav1d_default_settings(&settings)
        settings.n_threads = Int32(max(1, threads))
        guard dav1d_open(&context, &settings) == 0, context != nil,
              let pool = NV12PixelPool(width: width, height: height) else {
            return nil
        }
        pixelPool = pool
    }

    /// Drops any state from a previous segment: every segment starts on a
    /// key frame, and one may be asked for out of order after a seek.
    func reset() {
        dav1d_flush(context)
    }

    /// Feeds one temporal unit; any pictures that became ready go to `sink`.
    func decode(_ bytes: Data, timestamp: Int64, sink: (DecodedFrame) -> Void) -> Bool {
        var data = Dav1dData()
        guard let buffer = dav1d_data_create(&data, bytes.count) else {
            return false
        }
        bytes.copyBytes(to: buffer, count: bytes.count)
        data.m.timestamp = timestamp
        while data.sz > 0 {
            let result = dav1d_send_data(context, &data)
            if result != 0, result != -EAGAIN {
                dav1d_data_unref(&data)
                return false
            }
            drainReady(sink: sink)
        }
        return true
    }

    /// Collects pictures still held back by frame threading once a segment's
    /// samples have all been sent.
    func drain(sink: (DecodedFrame) -> Void) {
        drainReady(sink: sink)
    }

    private func drainReady(sink: (DecodedFrame) -> Void) {
        var picture = Dav1dPicture()
        while dav1d_get_picture(context, &picture) == 0 {
            if picture.m.timestamp >= skipBefore, let frame = pixelPool.frame(from: picture) {
                sink(frame)
            }
            dav1d_picture_unref(&picture)
        }
    }

    deinit {
        dav1d_close(&context)
    }
}
