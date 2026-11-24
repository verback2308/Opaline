import Foundation

struct WatchProgress {
    let fraction: Double

    var shouldShow: Bool {
        fraction > 0.03
    }
}
