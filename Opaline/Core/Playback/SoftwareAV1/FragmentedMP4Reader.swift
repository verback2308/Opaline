import Foundation

/// What the AV1 track's init segment says about the stream.
struct AV1TrackInfo {
    let timescale: UInt32
    let width: Int
    let height: Int
    /// The `av1C` configOBUs — normally the sequence header, which a decoder
    /// needs if a segment's first sample does not repeat it.
    let configOBUs: Data
}

/// One AV1 temporal unit from a media segment.
struct MediaSample {
    let data: Data
    let decodeTime: UInt64
    let duration: UInt32
    let isSync: Bool
}

/// Reads the fragmented MP4 that YouTube's DASH formats are served as: one
/// `moov` in the init segment, then `moof`/`mdat` pairs.
enum FragmentedMP4Reader {
    static func trackInfo(fromInit data: Data) -> AV1TrackInfo? {
        let mdia = ["moov", "trak", "mdia"]
        guard let mdhd = MP4Box.find(mdia + ["mdhd"], in: data),
              let stsd = MP4Box.find(mdia + ["minf", "stbl", "stsd"], in: data) else {
            return nil
        }
        // mdhd: version, then 32- or 64-bit creation/modification times.
        let version = data.mp4UInt8(at: mdhd.payload.lowerBound)
        let timescale = data.mp4UInt32(at: mdhd.payload.lowerBound + (version == 1 ? 20 : 12))
        // stsd: version/flags and entry count, then the av01 sample entry.
        let entries = MP4Box.children(
            of: data,
            in: (stsd.payload.lowerBound + 8)..<stsd.payload.upperBound
        )
        guard let entry = entries.first(where: { $0.type == "av01" }) else {
            return nil
        }
        return sampleEntryInfo(entry, in: data, timescale: timescale)
    }

    /// Visual sample entry: 24 bytes of reserved and pre-defined fields, then
    /// width and height, then 50 more bytes before the child boxes.
    private static func sampleEntryInfo(
        _ entry: MP4Box,
        in data: Data,
        timescale: UInt32
    ) -> AV1TrackInfo? {
        let start = entry.payload.lowerBound
        let children = MP4Box.children(of: data, in: (start + 78)..<entry.payload.upperBound)
        guard let av1C = children.first(where: { $0.type == "av1C" }),
              av1C.payload.count >= 4 else {
            return nil
        }
        return AV1TrackInfo(
            timescale: timescale,
            width: Int(data.mp4UInt16(at: start + 24)),
            height: Int(data.mp4UInt16(at: start + 26)),
            configOBUs: data.mp4Slice((av1C.payload.lowerBound + 4)..<av1C.payload.upperBound)
        )
    }

    /// Every sample of every fragment in a media segment, in decode order.
    static func samples(fromSegment data: Data) -> [MediaSample] {
        let top = MP4Box.children(of: data, in: 0..<data.count)
        var samples: [MediaSample] = []
        for box in top where box.type == "moof" {
            let moofStart = box.payload.lowerBound - 8
            guard let traf = MP4Box.children(of: data, in: box.payload)
                .first(where: { $0.type == "traf" }) else {
                continue
            }
            let parsed = TrackFragment(data: data, traf: traf, moofStart: moofStart)
            samples += parsed.samples()
        }
        return samples
    }
}
