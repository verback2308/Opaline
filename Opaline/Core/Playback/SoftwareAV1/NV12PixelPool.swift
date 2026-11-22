import Accelerate
import CoreVideo
import Dav1d
import Foundation

/// Converts dav1d's planar I420 pictures into IOSurface-backed NV12 pixel
/// buffers from a pool, so the encoder can read them without another copy.
final class NV12PixelPool {
    private let pool: CVPixelBufferPool

    init?(width: Int, height: Int) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
        guard let created else {
            return nil
        }
        pool = created
    }

    func frame(from picture: Dav1dPicture) -> DecodedFrame? {
        guard picture.p.layout == DAV1D_PIXEL_LAYOUT_I420, picture.p.bpc == 8,
              let planeY = picture.data.0, let planeU = picture.data.1,
              let planeV = picture.data.2 else {
            return nil
        }
        guard let output = makeBuffer() else {
            return nil
        }
        let planes = SourcePlanes(
            luma: planeY.assumingMemoryBound(to: UInt8.self),
            chromaU: planeU.assumingMemoryBound(to: UInt8.self),
            chromaV: planeV.assumingMemoryBound(to: UInt8.self),
            lumaStride: picture.stride.0,
            chromaStride: picture.stride.1
        )
        CVPixelBufferLockBaseAddress(output, [])
        copy(planes, into: output, width: Int(picture.p.w), height: Int(picture.p.h))
        CVPixelBufferUnlockBaseAddress(output, [])
        return DecodedFrame(pixelBuffer: output, timestamp: picture.m.timestamp)
    }

    func makeBuffer() -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        return output
    }

    private func copy(_ planes: SourcePlanes, into buffer: CVPixelBuffer, width: Int, height: Int) {
        let width = min(width, CVPixelBufferGetWidth(buffer))
        let height = min(height, CVPixelBufferGetHeight(buffer))
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<height {
                memcpy(luma + row * stride, planes.luma + row * planes.lumaStride, width)
            }
        }
        guard let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            return
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let out = chroma.assumingMemoryBound(to: UInt8.self)
        planes.interleaveChroma(into: out, stride: stride, width: width / 2, height: height / 2)
    }
}

/// dav1d's three planes for one picture.
private struct SourcePlanes {
    let luma: UnsafeMutablePointer<UInt8>
    let chromaU: UnsafeMutablePointer<UInt8>
    let chromaV: UnsafeMutablePointer<UInt8>
    let lumaStride: Int
    let chromaStride: Int

    /// NV12 keeps U and V interleaved in one plane: UVUV… — done with
    /// vImage, which vectorises it; a plain loop cost a few fps at 1440p60.
    func interleaveChroma(
        into out: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int
    ) {
        var planeU = buffer(chromaU, width: width, height: height)
        var planeV = buffer(chromaV, width: width, height: height)
        withUnsafePointer(to: &planeU) { pointerU in
            withUnsafePointer(to: &planeV) { pointerV in
                var sources: [UnsafePointer<vImage_Buffer>?] = [pointerU, pointerV]
                var destinations: [UnsafeMutableRawPointer?] = [
                    UnsafeMutableRawPointer(out),
                    UnsafeMutableRawPointer(out + 1)
                ]
                _ = vImageConvert_PlanarToChunky8(
                    &sources,
                    &destinations,
                    2,
                    2,
                    vImagePixelCount(width),
                    vImagePixelCount(height),
                    stride,
                    vImage_Flags(kvImageNoFlags)
                )
            }
        }
    }

    private func buffer(
        _ plane: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int
    ) -> vImage_Buffer {
        vImage_Buffer(
            data: plane,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: chromaStride
        )
    }
}

extension NV12PixelPool {
    /// A black frame, for priming the encoder.
    func blankFrame() -> DecodedFrame? {
        guard let buffer = makeBuffer() else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        for (plane, value) in [(0, UInt8(16)), (1, UInt8(128))] {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
                memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * rows)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return DecodedFrame(pixelBuffer: buffer, timestamp: 0)
    }
}
