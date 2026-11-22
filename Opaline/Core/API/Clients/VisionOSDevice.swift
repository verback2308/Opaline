import Foundation

/// The headset the VISIONOS client names itself as.
///
/// YouTube lists AV1 formats only to a device that decodes AV1 in hardware:
/// the M2 Vision Pro this client has always claimed to be gets VP9 above
/// 1080p, the M5 one gets av01 as well — with URLs that play through like
/// the rest (checked 2026-11-22). The newer one is named only while the
/// software AV1 beta wants those formats; otherwise nothing changes.
struct VisionOSDevice {
    static let visionProM2 = Self(model: "RealityDevice14,1", osVersion: "1.0.2.21O209")
    static let visionProM5 = Self(model: "RealityDevice17,1", osVersion: "26.0.23M336")

    static var current: Self {
        AV1Support.isSoftwareEnabled ? visionProM5 : visionProM2
    }

    let model: String
    let osVersion: String

    /// The client context with the current device in place of the template's.
    static func apply(to body: [String: Any]) -> [String: Any] {
        var result = body
        guard var context = result["context"] as? [String: Any],
              var client = context["client"] as? [String: Any] else {
            return result
        }
        client["deviceModel"] = current.model
        client["osVersion"] = current.osVersion
        context["client"] = client
        result["context"] = context
        return result
    }
}
