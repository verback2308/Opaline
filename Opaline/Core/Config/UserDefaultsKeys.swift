import Foundation

/// Centralised UserDefaults key namespace.
/// All keys used in the app must be declared here to prevent typos and collisions.
enum UserDefaultsKeys {
    enum Theme {
        static let mode = "themeMode"
        static let autoDarkStartHour = "theme_autoDarkStartHour"
        static let autoDarkEndHour = "theme_autoDarkEndHour"
    }

    enum VideoQuality {
        /// The Wi-Fi preference. Keeps its original name so the setting
        /// everyone already made carries over as their Wi-Fi choice.
        static let selected = "defaultVideoQuality"
        static let selectedCellular = "defaultVideoQualityCellular"
    }

    enum Downloads {
        static let quality = "downloadQuality"
        static let comments = "downloadComments"
        static let captions = "downloadCaptions"
    }

    enum Cache {
        static let feedPersistenceEnabled = "feedCachePersistenceEnabled"
        static let feedCacheDays = "feedCacheDays"
        static let imageCacheEnabled = "imageCacheEnabled"
        static let imageCacheDays = "imageCacheDays"
        static let thumbnailQuality = "thumbnailQuality"

        /// When a feed was last written — read on launch to decide whether
        /// the screen may skip its network revalidation. Cheaper than
        /// reading the cache file just for its timestamp.
        static func feedUpdatedAt(_ feedKey: String) -> String {
            "cache_feedUpdatedAt_\(feedKey)"
        }
    }

    enum Auth {
        static let isAnonymous = "isAnonymous"
    }

    enum RYD {
        static let enabled    = "ryd_enabled"
        static let userId     = "ryd_userId_v2"
        static let registered = "ryd_registered_v2"
    }

    enum SponsorBlock {
        static let enabled = "sponsorblock_enabled"
        /// Returns the key for the skip-behavior setting of a given category raw value.
        static func segmentBehavior(for categoryRawValue: String) -> String {
            "sb_behavior_\(categoryRawValue)"
        }
    }

    enum Feed {
        static let showShorts = "feed_showShorts"
        /// `ShortsPlayerMode` raw value; absent = vertical viewer.
        static let shortsPlayer = "feed_shortsPlayer"
        /// Shorts shelf in the subscriptions feed; absent = grouped.
        static let groupShorts = "feed_groupShorts"
        static let homeLayout = "feed_homeLayout"
        /// `DefaultTab` raw value (= tab tag); absent = Home.
        static let defaultTab = "feed_defaultTab"
    }

    enum Search {
        static let history = "search_history"
    }

    enum Localization {
        /// In-app UI language override; absent = follow the system.
        static let appLanguage = "localization_appLanguage"
        /// Innertube `gl`; absent = device region.
        static let region = "localization_region"
    }

    enum Account {
        /// The signed-in user's own channel id, derived from the accounts
        /// list (`UC` + `offlineCacheKeyToken.clientCacheKey`).
        static let ownChannelId = "account_ownChannelId"
    }

    enum Playlists {
        /// Legacy "Favorites" playlist id (`FL` + channelId). The TV library
        /// browse omits it, so it is remembered the first time the
        /// add-to-playlist options mention it.
        static let legacyFavoritesId = "playlists_legacyFavoritesId"
    }

    enum Player {
        static let backgroundPlayback = "player_backgroundPlayback"
        static let pipEnabled = "player_pipEnabled"
        static let hideStatusBarInFullscreen = "player_hideStatusBarFullscreen"
        static let autoZoomToFill = "player_autoZoomToFill"
        static let openInFullscreen = "player_openInFullscreen"
    }

    enum Playback {
        /// The made-up television id the TV client presents once and keeps;
        /// its proof-of-origin token is bound to this exact string.
        static let livingRoomPoTokenId = "playback_livingRoomPoTokenId"
    }

    enum AutoDub {
        static let enabled = "autoDub_enabled"
        static let ignoreAIDubs = "autoDub_ignoreAIDubs"
        /// Preferred dub language code; absent = follow the app language.
        static let language = "autoDub_language"
    }

    enum Autoplay {
        /// Suggestion ("Up Next") autoplay: 5s countdown overlay.
        static let enabled = "autoplay_enabled"
        /// Mix/playlist queue autoplay: instant, no overlay.
        static let mixEnabled = "autoplay_mixEnabled"
    }

    enum Innertube {
        static let visitorData = "innertube_visitorData"
        static let visitorDataDate = "innertube_visitorDataDate"
    }

    enum Debug {
        /// The chain the user built: which steps play, and in what order.
        static let playbackChainOrder = "debug_playbackChainOrder"
        static let playbackChainEnabled = "debug_playbackChainEnabled"
        static let serverBaseURL = "debug_serverBaseURL"
        static let mainThreadWatchdog = "debug_mainThreadWatchdog"
    }

    enum Migration {
        static let playbackSourceAuto = "migration_playbackSourceAuto"
        /// Tokens stored before the keychain item became readable while the
        /// device is locked.
        static let keychainAfterFirstUnlock = "migration_keychainAfterFirstUnlock"
    }

    enum Notifications {
        static let appUpdatesEnabled = "notifications_appUpdates"
        static let lastUpdateCheck = "notifications_lastUpdateCheck"
        /// First launch of a build that has the inbox — nothing published
        /// before it is worth showing.
        static let featureInstallDate = "notifications_featureInstallDate"
    }
}
