import Foundation

/// Big-endian byte building for ISO-BMFF boxes.
struct MP4Writer {
    private(set) var data = Data()

    static func box(_ type: String, _ build: (inout Self) -> Void) -> Data {
        var payload = Self()
        build(&payload)
        var box = Self()
        box.uint32(UInt32(payload.data.count + 8))
        box.fourCC(type)
        box.bytes(payload.data)
        return box.data
    }

    static func fullBox(
        _ type: String,
        version: UInt8 = 0,
        flags: UInt32 = 0,
        _ build: (inout Self) -> Void
    ) -> Data {
        box(type) { writer in
            writer.uint32(UInt32(version) << 24 | flags & 0x00FF_FFFF)
            build(&writer)
        }
    }

    mutating func uint8(_ value: UInt8) {
        data.append(value)
    }

    mutating func uint16(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    mutating func uint32(_ value: UInt32) {
        uint16(UInt16(value >> 16))
        uint16(UInt16(value & 0xFFFF))
    }

    mutating func uint64(_ value: UInt64) {
        uint32(UInt32(value >> 32))
        uint32(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func zeros(_ count: Int) {
        data.append(Data(count: count))
    }

    mutating func fourCC(_ code: String) {
        data.append(contentsOf: Array(code.utf8.prefix(4)))
    }

    mutating func bytes(_ other: Data) {
        data.append(other)
    }

    /// The identity transform every `mvhd` and `tkhd` carries.
    mutating func unityMatrix() {
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] {
            uint32(value)
        }
    }
}
