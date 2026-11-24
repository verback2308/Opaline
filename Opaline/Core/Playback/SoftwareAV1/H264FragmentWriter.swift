import Foundation

/// Writes the fragmented MP4 AVPlayer reads over HLS: an init segment
/// describing one H.264 track, then one `moof`/`mdat` per media segment.
/// Timestamps are the source track's, in its timescale, so the transcoded
/// video stays on the same timeline as the untouched audio.
struct H264FragmentWriter {
    /// `sample_depends_on = 2` for key frames; non-sync plus depends-on
    /// for the rest.
    private static let syncFlags: UInt32 = 0x0200_0000
    private static let nonSyncFlags: UInt32 = 0x0101_0000

    let width: Int
    let height: Int
    let timescale: UInt32
    let parameterSets: H264ParameterSets

    func initSegment() -> Data {
        let ftyp = MP4Writer.box("ftyp") { writer in
            writer.fourCC("iso5")
            writer.uint32(512)
            ["iso5", "iso6", "mp41", "avc1"].forEach { writer.fourCC($0) }
        }
        let moov = MP4Writer.box("moov") { writer in
            writer.bytes(movieHeader())
            writer.bytes(track())
            writer.bytes(MP4Writer.box("mvex") { mvex in
                mvex.bytes(MP4Writer.fullBox("trex") { trex in
                    trex.uint32(1)
                    trex.uint32(1)
                    trex.zeros(12)
                })
            })
        }
        return ftyp + moov
    }

    /// One media segment. `samples` carry their own timestamps; each one's
    /// duration runs to the next, the last one's is `lastDuration`.
    func mediaSegment(
        sequence: UInt32,
        samples: [EncodedSample],
        lastDuration: UInt32
    ) -> Data {
        guard let first = samples.first else {
            return Data()
        }
        let durations = zip(samples, samples.dropFirst()).map {
            UInt32(clamping: $1.timestamp - $0.timestamp)
        } + [lastDuration]
        let rows = zip(samples, durations).map { sample, duration in
            FragmentRow(duration: duration, size: UInt32(sample.data.count), isSync: sample.isSync)
        }
        let baseTime = UInt64(max(0, first.timestamp))
        let placeholder = movieFragment(
            sequence: sequence,
            baseTime: baseTime,
            rows: rows,
            offset: 0
        )
        let moof = movieFragment(
            sequence: sequence,
            baseTime: baseTime,
            rows: rows,
            offset: Int32(placeholder.count + 8)
        )
        let payload = samples.reduce(into: Data()) { $0.append($1.data) }
        let mdat = MP4Writer.box("mdat") { $0.bytes(payload) }
        return moof + mdat
    }

    private func movieFragment(
        sequence: UInt32,
        baseTime: UInt64,
        rows: [FragmentRow],
        offset: Int32
    ) -> Data {
        MP4Writer.box("moof") { moof in
            moof.bytes(MP4Writer.fullBox("mfhd") { $0.uint32(sequence) })
            moof.bytes(MP4Writer.box("traf") { traf in
                // default-base-is-moof
                traf.bytes(MP4Writer.fullBox("tfhd", flags: 0x02_0000) { $0.uint32(1) })
                traf.bytes(MP4Writer.fullBox("tfdt", version: 1) { $0.uint64(baseTime) })
                traf.bytes(MP4Writer.fullBox("trun", flags: 0x0701) { trun in
                    trun.uint32(UInt32(rows.count))
                    trun.uint32(UInt32(bitPattern: offset))
                    for row in rows {
                        trun.uint32(row.duration)
                        trun.uint32(row.size)
                        trun.uint32(row.isSync ? Self.syncFlags : Self.nonSyncFlags)
                    }
                })
            })
        }
    }

    private func movieHeader() -> Data {
        MP4Writer.fullBox("mvhd") { mvhd in
            mvhd.zeros(8)
            mvhd.uint32(timescale)
            mvhd.uint32(0)
            mvhd.uint32(0x0001_0000)
            mvhd.uint16(0x0100)
            mvhd.zeros(10)
            mvhd.unityMatrix()
            mvhd.zeros(24)
            mvhd.uint32(2)
        }
    }

    private func track() -> Data {
        MP4Writer.box("trak") { trak in
            trak.bytes(MP4Writer.fullBox("tkhd", flags: 3) { tkhd in
                // creation and modification times, track id, then reserved,
                // duration, reserved[2], layer, group, volume and reserved
                tkhd.zeros(8)
                tkhd.uint32(1)
                tkhd.zeros(24)
                tkhd.unityMatrix()
                tkhd.uint32(UInt32(width) << 16)
                tkhd.uint32(UInt32(height) << 16)
            })
            trak.bytes(media())
        }
    }

    private func media() -> Data {
        MP4Writer.box("mdia") { mdia in
            mdia.bytes(MP4Writer.fullBox("mdhd") { mdhd in
                mdhd.zeros(8)
                mdhd.uint32(timescale)
                mdhd.uint32(0)
                mdhd.uint16(0x55C4)
                mdhd.uint16(0)
            })
            mdia.bytes(MP4Writer.fullBox("hdlr") { hdlr in
                hdlr.uint32(0)
                hdlr.fourCC("vide")
                hdlr.zeros(12)
                hdlr.bytes(Data("VideoHandler\0".utf8))
            })
            mdia.bytes(mediaInformation())
        }
    }

    private func mediaInformation() -> Data {
        MP4Writer.box("minf") { minf in
            minf.bytes(MP4Writer.fullBox("vmhd", flags: 1) { $0.zeros(8) })
            minf.bytes(MP4Writer.box("dinf") { dinf in
                dinf.bytes(MP4Writer.fullBox("dref") { dref in
                    dref.uint32(1)
                    dref.bytes(MP4Writer.fullBox("url ", flags: 1) { _ in })
                })
            })
            minf.bytes(MP4Writer.box("stbl") { stbl in
                stbl.bytes(MP4Writer.fullBox("stsd") { stsd in
                    stsd.uint32(1)
                    stsd.bytes(sampleEntry())
                })
                ["stts", "stsc", "stco"].forEach { type in
                    stbl.bytes(MP4Writer.fullBox(type) { $0.uint32(0) })
                }
                stbl.bytes(MP4Writer.fullBox("stsz") { $0.zeros(8) })
            })
        }
    }

    private func sampleEntry() -> Data {
        MP4Writer.box("avc1") { entry in
            entry.zeros(6)
            entry.uint16(1)
            entry.zeros(16)
            entry.uint16(UInt16(width))
            entry.uint16(UInt16(height))
            entry.uint32(0x0048_0000)
            entry.uint32(0x0048_0000)
            entry.uint32(0)
            entry.uint16(1)
            entry.zeros(32)
            entry.uint16(0x0018)
            entry.uint16(0xFFFF)
            entry.bytes(decoderConfiguration())
        }
    }

    private func decoderConfiguration() -> Data {
        let sps = parameterSets.sps
        let pps = parameterSets.pps
        return MP4Writer.box("avcC") { avcC in
            avcC.uint8(1)
            avcC.uint8(sps.mp4UInt8(at: 1))
            avcC.uint8(sps.mp4UInt8(at: 2))
            avcC.uint8(sps.mp4UInt8(at: 3))
            avcC.uint8(0xFF)
            avcC.uint8(0xE1)
            avcC.uint16(UInt16(sps.count))
            avcC.bytes(sps)
            avcC.uint8(1)
            avcC.uint16(UInt16(pps.count))
            avcC.bytes(pps)
        }
    }
}

/// One sample's row in the written `trun`.
private struct FragmentRow {
    let duration: UInt32
    let size: UInt32
    let isSync: Bool
}
