import Foundation

/// The per-sample values a `tfhd` supplies for any field a `trun` omits.
private struct FragmentDefaults {
    var duration: UInt32 = 0
    var size: UInt32 = 0
    var flags: UInt32 = 0
}

/// One sample's row in a `trun`.
private struct RunEntry {
    let size: Int
    let duration: UInt32
    let flags: UInt32
}

/// Where a `trun`'s sample rows begin and what precedes them.
private struct RunHeader {
    let flags: UInt32
    let count: Int
    let rowsStart: Int
    let dataOffset: Int
    let firstFlags: UInt32?
}

/// Walks a `trun`'s per-sample fields, falling back to the `tfhd` defaults
/// for any the run leaves out.
private struct RunReader {
    let header: RunHeader
    let defaults: FragmentDefaults
    var cursor: Int

    mutating func next(in data: Data, index: Int) -> RunEntry {
        let duration = field(0x100, in: data) ?? defaults.duration
        let size = field(0x200, in: data) ?? defaults.size
        var flags = field(0x400, in: data) ?? defaults.flags
        if index == 0, let first = header.firstFlags {
            flags = first
        }
        // Composition offsets: AV1 in MP4 has none worth honouring.
        _ = field(0x800, in: data)
        return RunEntry(size: Int(size), duration: duration, flags: flags)
    }

    private mutating func field(_ bit: UInt32, in data: Data) -> UInt32? {
        guard header.flags & bit != 0 else {
            return nil
        }
        defer { cursor += 4 }
        return data.mp4UInt32(at: cursor)
    }
}

/// One `traf`: its defaults from `tfhd`, its start time from `tfdt`, and the
/// per-sample table in `trun`.
struct TrackFragment {
    private static let nonSyncFlag: UInt32 = 0x0001_0000

    let data: Data
    let traf: MP4Box
    /// `default-base-is-moof`: trun data offsets count from the moof's start.
    let moofStart: Int

    func samples() -> [MediaSample] {
        let boxes = MP4Box.children(of: data, in: traf.payload)
        guard let trun = boxes.first(where: { $0.type == "trun" }) else {
            return []
        }
        let defaults = boxes.first { $0.type == "tfhd" }.map(readDefaults) ?? FragmentDefaults()
        let baseTime = boxes.first { $0.type == "tfdt" }.map(readBaseTime) ?? 0
        return readRun(readHeader(trun), defaults: defaults, baseTime: baseTime)
    }

    private func readDefaults(_ tfhd: MP4Box) -> FragmentDefaults {
        let flags = data.mp4UInt32(at: tfhd.payload.lowerBound) & 0x00FF_FFFF
        // Skip version/flags and track id, then the optional base data offset
        // and sample description index.
        var cursor = tfhd.payload.lowerBound + 8
        cursor += flags & 0x01 != 0 ? 8 : 0
        cursor += flags & 0x02 != 0 ? 4 : 0
        var defaults = FragmentDefaults()
        for (bit, keyPath) in [
            (UInt32(0x08), \FragmentDefaults.duration),
            (0x10, \FragmentDefaults.size),
            (0x20, \FragmentDefaults.flags)
        ] where flags & bit != 0 {
            defaults[keyPath: keyPath] = data.mp4UInt32(at: cursor)
            cursor += 4
        }
        return defaults
    }

    private func readBaseTime(_ tfdt: MP4Box) -> UInt64 {
        let start = tfdt.payload.lowerBound
        return data.mp4UInt8(at: start) == 1
            ? data.mp4UInt64(at: start + 4)
            : UInt64(data.mp4UInt32(at: start + 4))
    }

    private func readHeader(_ trun: MP4Box) -> RunHeader {
        let start = trun.payload.lowerBound
        let flags = data.mp4UInt32(at: start) & 0x00FF_FFFF
        var cursor = start + 8
        var dataOffset = moofStart
        if flags & 0x01 != 0 {
            dataOffset += Int(Int32(bitPattern: data.mp4UInt32(at: cursor)))
            cursor += 4
        }
        var firstFlags: UInt32?
        if flags & 0x04 != 0 {
            firstFlags = data.mp4UInt32(at: cursor)
            cursor += 4
        }
        return RunHeader(
            flags: flags,
            count: Int(data.mp4UInt32(at: start + 4)),
            rowsStart: cursor,
            dataOffset: dataOffset,
            firstFlags: firstFlags
        )
    }

    private func readRun(
        _ header: RunHeader,
        defaults: FragmentDefaults,
        baseTime: UInt64
    ) -> [MediaSample] {
        var reader = RunReader(header: header, defaults: defaults, cursor: header.rowsStart)
        var samples: [MediaSample] = []
        var offset = header.dataOffset
        var time = baseTime
        for index in 0..<header.count {
            let entry = reader.next(in: data, index: index)
            guard offset + entry.size <= data.count else {
                break
            }
            samples.append(MediaSample(
                data: data.mp4Slice(offset..<(offset + entry.size)),
                decodeTime: time,
                duration: entry.duration,
                isSync: entry.flags & Self.nonSyncFlag == 0
            ))
            offset += entry.size
            time += UInt64(entry.duration)
        }
        return samples
    }
}
