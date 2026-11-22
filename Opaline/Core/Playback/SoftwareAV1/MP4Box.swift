import Foundation

/// One ISO-BMFF box: its four-character type and where its payload sits in
/// the buffer it was read from (header excluded, offsets from the start).
struct MP4Box {
    let type: String
    let payload: Range<Int>

    /// The boxes laid out back to back in `range` of `data`. Stops at the
    /// first malformed header rather than reading past the buffer.
    static func children(of data: Data, in range: Range<Int>) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            guard let box = box(in: data, at: offset, limit: range.upperBound) else {
                break
            }
            boxes.append(box)
            offset = box.payload.upperBound
        }
        return boxes
    }

    /// Follows `path` down from the top level, taking the first match at each
    /// step.
    static func find(_ path: [String], in data: Data) -> MP4Box? {
        var range = 0..<data.count
        var found: MP4Box?
        for type in path {
            guard let next = children(of: data, in: range).first(where: { $0.type == type }) else {
                return nil
            }
            found = next
            range = next.payload
        }
        return found
    }

    private static func box(in data: Data, at offset: Int, limit: Int) -> MP4Box? {
        var size = Int(data.mp4UInt32(at: offset))
        var header = 8
        if size == 1 {
            guard offset + 16 <= limit else {
                return nil
            }
            size = Int(data.mp4UInt64(at: offset + 8))
            header = 16
        } else if size == 0 {
            size = limit - offset
        }
        guard size >= header, offset + size <= limit else {
            return nil
        }
        return MP4Box(
            type: data.mp4FourCC(at: offset + 4),
            payload: (offset + header)..<(offset + size)
        )
    }
}

// MARK: - Big-endian reads

extension Data {
    /// Offsets are from the start of the data, whatever its `startIndex`.
    func mp4UInt8(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func mp4UInt16(at offset: Int) -> UInt16 {
        UInt16(mp4UInt8(at: offset)) << 8 | UInt16(mp4UInt8(at: offset + 1))
    }

    func mp4UInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(mp4UInt8(at: offset + $1)) }
    }

    func mp4UInt64(at offset: Int) -> UInt64 {
        UInt64(mp4UInt32(at: offset)) << 32 | UInt64(mp4UInt32(at: offset + 4))
    }

    func mp4FourCC(at offset: Int) -> String {
        let bytes = (0..<4).map { mp4UInt8(at: offset + $0) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// The bytes at `range`, re-based so the copy starts at index 0.
    func mp4Slice(_ range: Range<Int>) -> Data {
        Data(self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)])
    }
}
