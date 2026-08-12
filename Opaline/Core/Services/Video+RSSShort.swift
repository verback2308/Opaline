import Foundation

extension Video {
    /// A short built from its channel's Atom entry. The feed gives
    /// everything a shorts card shows except the duration, which the card
    /// doesn't show anyway; the poster is derived from the video id.
    init(short entry: RSSVideoEntry, channel: SubscribedChannel) {
        self.init(
            id: entry.videoId,
            title: entry.title,
            channelId: channel.id,
            channelName: channel.title,
            channelAvatarURL: channel.avatarURL,
            thumbnailURL: AppURLs.YouTube.thumbnailURL(
                videoId: entry.videoId
            ),
            viewCount: entry.viewCount.map {
                VideoFormatters.formatViewCount(String($0))
            },
            publishedAt: VideoFormatters.formatRelativeDate(entry.published),
            duration: nil,
            isShort: true
        )
    }
}
