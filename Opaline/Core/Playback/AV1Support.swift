import Foundation
import VideoToolbox

/// AV1 decode capability. YouTube serves 1440p+/4K only as VP9 or AV1;
/// AVPlayer can never decode VP9, and decodes AV1 solely in hardware
/// (A17 Pro+, HLS support since iOS 17.4). `av01` formats are admitted to
/// the DASH ladder on devices that pass the hardware check, and — as an
/// opt-in beta — on older ones through the software transcoder (#15, #69).
enum AV1Support {
    /// Software decode pays only above 1080p, where AVC stops, and stays
    /// comfortable up to 1440p even on an A9X; 2160p does not.
    static let softwareMaxHeight = 1_440

    static let isHardwareSupported: Bool = {
        guard #available(iOS 17.4, *) else {
            return false
        }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }()

    /// Software decode needs dav1d, which the default build leaves out to
    /// stay dependency-free; `scripts/build_dav1d.sh` adds it.
    static let isSoftwareAvailable: Bool = {
        #if canImport(Dav1d)
        return !isHardwareSupported
        #else
        return false
        #endif
    }()

    private static let lock = NSLock()
    /// Format shapes ("1440x60") the transcoder could not set up for.
    private static var failedShapes = Set<String>()

    /// The stored beta setting — what the switch in Settings shows.
    static var isSoftwarePreferred: Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.Playback.softwareAV1)
    }

    /// The beta setting, on a device that needs it, in a build that has it.
    static var isSoftwareEnabled: Bool {
        isSoftwareAvailable && isSoftwarePreferred
    }

    /// Takes a format shape out of the beta for the rest of the launch after
    /// the transcoder could not set up for it — the next attempt then picks
    /// another format and plays, rather than failing the same way again.
    static func markSoftwareUnavailable(height: Int, fps: Int) {
        lock.lock()
        failedShapes.insert("\(height)x\(fps)")
        lock.unlock()
    }

    /// Whether a format may be offered through the transcoder: 8-bit AV1
    /// (SDR; dav1d's 10-bit output is not converted) above 1080p.
    static func isSoftwarePlayable(mime: String, height: Int, fps: Int) -> Bool {
        lock.lock()
        let failed = failedShapes.contains("\(height)x\(fps)")
        lock.unlock()
        return isSoftwareEnabled
            && !failed
            && mime.contains("av01")
            && mime.contains(".08")
            && height > 1_080
            && height <= softwareMaxHeight
    }

    /// Whether a format has to go through the transcoder to play at all.
    static func needsTranscode(_ format: DashFormatInfo) -> Bool {
        !isHardwareSupported && format.codecs.hasPrefix("av01")
    }
}
