import Foundation

/// One named section of a video, as YouTube's own player shows it on the
/// seek bar (chapters from the description, or auto-generated ones).
struct VideoChapter: Codable, Equatable {
    let title: String
    /// Where the chapter starts, in seconds from the start of the video.
    let start: Double

    /// The chapter playing at `seconds`, or nil before the first one starts.
    static func index(at seconds: Double, in chapters: [Self]) -> Int? {
        chapters.lastIndex { $0.start <= seconds }
    }
}
