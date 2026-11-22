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

    /// The beta setting, on a device that needs it.
    static var isSoftwareEnabled: Bool {
        !isHardwareSupported
            && UserDefaults.standard.bool(forKey: UserDefaultsKeys.Playback.softwareAV1)
    }

    /// Whether a format may be offered through the transcoder: 8-bit AV1
    /// (SDR; dav1d's 10-bit output is not converted) above 1080p.
    static func isSoftwarePlayable(mime: String, height: Int) -> Bool {
        isSoftwareEnabled
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
