import CoreVideo
import Foundation
#if canImport(Dav1d)
import Dav1d
#endif

/// A decoded picture and the decode time of the sample it came from.
struct DecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: Int64
}

#if canImport(Dav1d)
/// dav1d behind a minimal push/pull interface. Pictures come out as NV12
/// `CVPixelBuffer`s, the layout VideoToolbox's encoder takes without a copy
/// of its own. Only 8-bit 4:2:0 is supported — what YouTube's SDR AV1 is.
final class AV1Decoder {
    private enum PictureResult {
        case delivered, notReady, failed
    }

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
        // dav1d's documented loop: one picture per send. Asking again until
        // it has none would make it drain — wait out every frame in flight —
        // and frame threading would never overlap anything.
        repeat {
            let sent = dav1d_send_data(context, &data)
            guard sent == 0 || sent == -EAGAIN, nextPicture(sink: sink) != .failed else {
                dav1d_data_unref(&data)
                return false
            }
        } while data.sz > 0
        return true
    }

    /// Collects the pictures frame threading still holds once a segment's
    /// samples have all been sent.
    func drain(sink: (DecodedFrame) -> Void) {
        while nextPicture(sink: sink) == .delivered {}
    }

    private func nextPicture(sink: (DecodedFrame) -> Void) -> PictureResult {
        var picture = Dav1dPicture()
        let result = dav1d_get_picture(context, &picture)
        guard result == 0 else {
            return result == -EAGAIN ? .notReady : .failed
        }
        if picture.m.timestamp >= skipBefore, let frame = pixelPool.frame(from: picture) {
            sink(frame)
        }
        dav1d_picture_unref(&picture)
        return .delivered
    }

    deinit {
        dav1d_close(&context)
    }
}
#else
/// Builds without dav1d (see scripts/build_dav1d.sh) have no software
/// decoder; `AV1Support` keeps the beta hidden there, so this never runs.
final class AV1Decoder {
    var skipBefore = Int64.min

    init?(width: Int, height: Int, threads: Int) {
        nil
    }

    func reset() {}

    func decode(_ bytes: Data, timestamp: Int64, sink: (DecodedFrame) -> Void) -> Bool {
        false
    }

    func drain(sink: (DecodedFrame) -> Void) {}
}
#endif
