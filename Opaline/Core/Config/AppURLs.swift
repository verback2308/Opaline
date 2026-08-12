import Foundation

/// Centralised API base-URL namespace.
/// Actual endpoint paths are built locally in each service, but base URLs live here.
enum AppURLs {
    enum YouTube {
        static let base      = "https://www.youtube.com"
        static let innertube = "https://www.youtube.com/youtubei/v1"
        static let tv        = "https://www.youtube.com/tv"

        /// Stable fallback thumbnail URL for a given video ID. The thumbnail
        /// loader adds higher-resolution candidates when this is used.
        static func thumbnailURL(videoId: String) -> String {
            "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
        }

        /// Public per-channel Atom feed (unauthenticated, last ~15
        /// uploads with exact publish dates). Powers the new-content
        /// dots without touching the relevance-ranked subscriptions feed.
        static func channelRSSFeedURL(channelId: String) -> URL? {
            URL(string: base + "/feeds/videos.xml?channel_id=" + channelId)
        }

        /// Same Atom feed restricted to long-form uploads via the
        /// undocumented `UULF` system playlist (Shorts excluded). nil
        /// for non-`UC` channel ids — callers fall back to the full feed.
        static func channelLongFormRSSFeedURL(channelId: String) -> URL? {
            guard channelId.hasPrefix("UC") else {
                return nil
            }
            let playlistId = "UULF" + channelId.dropFirst(2)
            return URL(
                string: base + "/feeds/videos.xml?playlist_id=" + playlistId
            )
        }

        /// The mirror image: the undocumented `UUSH` system playlist holds
        /// the channel's Shorts and nothing else. nil for non-`UC` ids.
        static func channelShortsRSSFeedURL(channelId: String) -> URL? {
            guard channelId.hasPrefix("UC") else {
                return nil
            }
            let playlistId = "UUSH" + channelId.dropFirst(2)
            return URL(
                string: base + "/feeds/videos.xml?playlist_id=" + playlistId
            )
        }
    }

    enum YouTubeOAuth {
        static let deviceCode = "https://www.youtube.com/o/oauth2/device/code"
        static let token      = "https://www.youtube.com/o/oauth2/token"
    }

    /// The deployed `solver-server` (n-solve + GVS pot mint). Only the base URL
    /// (host) is configured; the app derives `/solve` and `/get_pot` from it.
    /// Runtime override: `Debug.serverBaseURL` (empty = the built-in default).
    enum SolverServer {
        static let defaultBaseURL =
            "https://ytlite-solver.wonderfulpond-77505dfd.westus2.azurecontainerapps.io"

        /// The effective base URL — the runtime override if set, else the
        /// default — with any trailing slash trimmed.
        static var baseURL: String {
            let override = UserDefaults.standard.string(
                forKey: UserDefaultsKeys.Debug.serverBaseURL
            )
            let value = (override?.isEmpty == false) ? (override ?? "") : defaultBaseURL
            return value.hasSuffix("/") ? String(value.dropLast()) : value
        }

        static func endpoint(path: String) -> URL? {
            baseURL.isEmpty ? nil : URL(string: baseURL + path)
        }
    }

    /// Remote n-throttling solver (`/solve`). Only the mweb+pot source uses it.
    enum NSolver {
        static var endpoint: URL? { SolverServer.endpoint(path: "/solve") }
    }

    enum GoogleAPIs {
        static let youtubeV3 = "https://www.googleapis.com/youtube/v3"
    }

    /// Donation page opened from Settings — most users install from the
    /// repo or a bare IPA and never see the README link.
    enum Support {
        static let donate = "https://buymeacoffee.com/verback2308"
    }

    /// Release manifest used to detect newer app versions for the
    /// in-app notification inbox ("app update available").
    /// The value is a build setting (`APP_MANIFEST_URL` in
    /// `Config/App.xcconfig` → `AppManifestURL` in Info.plist), so a fork
    /// points at its own feed without touching code. Empty when the build
    /// setting is missing — the poller then logs "bad manifest URL".
    enum AppManifest {
        static var source: String {
            Bundle.main.object(forInfoDictionaryKey: "AppManifestURL") as? String ?? ""
        }
    }

    /// Where the Settings feedback row sends people. The chooser rather than a
    /// blank issue, so reports arrive shaped by the templates in
    /// `.github/ISSUE_TEMPLATE/` instead of as free text.
    enum Feedback {
        static let issues = URL(string: "https://github.com/verback2308/Opaline/issues/new/choose")
    }

    /// Remote GVS proof-of-origin (`pot`) provider — the `solver-server`'s
    /// `/get_pot` endpoint (BotGuard minting can't be done reliably on-device).
    /// `POST /get_pot {"content_binding": <videoId>}`.
    enum PoTokenProvider {
        static var endpoint: URL? { SolverServer.endpoint(path: "/get_pot") }
    }

    enum RYD {
        static let api = "https://returnyoutubedislikeapi.com"
        static let web = "https://returnyoutubedislike.com"
    }

    enum SponsorBlock {
        static let api = "https://sponsor.ajay.app"
    }

    /// Public YouTube search autocomplete (unauthenticated).
    /// `client=firefox` returns plain JSON: `["<query>", [suggestions]]`.
    enum Suggest {
        static let base = "https://suggestqueries.google.com"

        static func searchURL(query: String) -> URL? {
            var components = URLComponents(
                string: base + "/complete/search"
            )
            var items = [
                URLQueryItem(name: "client", value: "firefox"),
                URLQueryItem(name: "ds", value: "yt"),
                // Without oe the reply charset follows hl
                // (e.g. windows-1251 for ru) and breaks JSON parsing.
                URLQueryItem(name: "oe", value: "utf-8"),
                URLQueryItem(name: "q", value: query)
            ]
            // Follows the content-language setting (not the device locale)
            // so suggestions match what feeds/search return.
            items.append(
                URLQueryItem(
                    name: "hl",
                    value: InnertubeContexts.localePreferences.hl
                )
            )
            components?.queryItems = items
            return components?.url
        }
    }
}
