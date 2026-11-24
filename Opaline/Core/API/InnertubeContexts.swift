import Foundation

enum InnertubeContexts {
    /// Content language/region source. Defaults to the UserDefaults-backed
    /// implementation; the composition root may override (tests, previews).
    static var localePreferences: LocalePreferences = DefaultLocalePreferences()

    // Public accessors: each template with the user's `hl`/`gl` applied.
    // The ONE deliberate exception is visitorData minting
    // (InnertubeClient+VisitorData) — its context/headers stay English for
    // BotGuard/fingerprint stability and do not come from here.
    /// The web client is only ever named in headers beside `webTemplate` —
    /// it has no playback path of its own.
    static let webClientHeaderName = "1"
    static let webClientVersion = "2.20231121.08.00"

    static var web: [String: Any] { localized(webTemplate) }
    static var tv: [String: Any] { localized(tvTemplate) }
    static var mweb: [String: Any] { localized(mwebTemplate) }
    static var android: [String: Any] { localized(androidTemplate) }
    static var visionOS: [String: Any] { VisionOSDevice.apply(to: localized(visionOSTemplate)) }
    static var ios: [String: Any] { localized(iosTemplate) }

    private static let webTemplate: [String: Any] = [
        "context": [
            "client": [
                "clientName": "WEB",
                "clientVersion": "2.20260206.01.00",
                "hl": "en",
                "gl": "US",
                "osName": "Windows",
                "osVersion": "10.0",
                "platform": "DESKTOP",
                "clientFormFactor": "UNKNOWN_FORM_FACTOR",
                "userInterfaceTheme": "USER_INTERFACE_THEME_LIGHT",
                "timeZone": "UTC",
                "utcOffsetMinutes": 0,
                "screenDensityFloat": 1,
                "screenHeightPoints": 1_440,
                "screenPixelDensity": 1,
                "screenWidthPoints": 2_560,
                "deviceMake": "",
                "deviceModel": "",
                "browserName": "Chrome",
                "browserVersion": "140.0.0.0",
                "userAgent": UserAgent.chromeDesktop,
                "originalUrl": "https://www.youtube.com",
                "memoryTotalKbytes": "8000000",
                "mainAppWebInfo": [
                    "graftUrl": "https://www.youtube.com",
                    "pwaInstallabilityStatus": "PWA_INSTALLABILITY_STATUS_UNKNOWN",
                    "webDisplayMode": "WEB_DISPLAY_MODE_BROWSER",
                    "isWebNativeShareAvailable": true
                ]
            ],
            "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
            "request": ["useSsl": true, "internalExperimentFlags": []]
        ]
    ]
    private static let tvTemplate: [String: Any] = [
        "context": [
            "client": [
                "clientName": "TVHTML5",
                "clientVersion": "7.20260311.12.00",
                "hl": "en",
                "gl": "US",
                "platform": "TV",
                "clientFormFactor": "UNKNOWN_FORM_FACTOR"
            ],
            "user": ["enableSafetyMode": false, "lockedSafetyMode": false],
            "request": ["useSsl": true, "internalExperimentFlags": []]
        ]
    ]
    /// Mobile web client. Logged-out, so its GVS `pot` binds to visitorData —
    /// matching the anonymous BotGuard token we mint (unlike authed TVHTML5,
    /// whose pot binds to the account datasyncId).
    private static let mwebTemplate: [String: Any] = [
        "context": [
            "client": [
                "clientName": "MWEB",
                "clientVersion": "2.20250101.00.00",
                "hl": "en",
                "gl": "US",
                "userAgent": UserAgent.mobileSafari
            ]
        ]
    ]
    private static let androidTemplate: [String: Any] = [
        "context": [
            "client": [
                "clientName": "ANDROID",
                "clientVersion": "21.26.364",
                "hl": "en",
                "gl": "US",
                "androidSdkVersion": 30,
                "osName": "Android",
                "osVersion": "11",
                "userAgent": UserAgent.androidPhone
            ],
            "user": [
                "enableSafetyMode": false,
                "lockedSafetyMode": false
            ],
            "request": [
                "useSsl": true,
                "internalExperimentFlags": []
            ]
        ]
    ]

    /// Apple Vision Pro's client. The one client still served media past the
    /// first minute of a video anonymously — every other one is cut off there
    /// (measured 2026-08-18, see Opaline#76).
    private static let visionOSTemplate: [String: Any] = [
        "context": [
            "client": [
                "clientName": "VISIONOS",
                "clientVersion": "1.02",
                "hl": "en",
                "timeZone": "UTC",
                "utcOffsetMinutes": 0,
                "deviceMake": "Apple",
                "deviceModel": "RealityDevice14,1",
                "osName": "visionOS",
                "osVersion": "1.0.2.21O209",
                "userAgent": UserAgent.visionOS
            ]
        ]
    ]

    private static let iosTemplate: [String: Any] = [
        "context": [
            "client": [
                "clientName": "IOS",
                "clientVersion": "20.10.4",
                "hl": "en",
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.3.2.22D82",
                "userAgent": UserAgent.iosYouTube
            ]
        ]
    ]

    /// Overrides `context.client.hl`/`gl` with the user's preferences.
    private static func localized(
        _ template: [String: Any]
    ) -> [String: Any] {
        var result = template
        guard var context = result["context"] as? [String: Any],
              var client = context["client"] as? [String: Any] else {
            return result
        }
        client["hl"] = localePreferences.hl
        client["gl"] = localePreferences.gl
        context["client"] = client
        result["context"] = context
        return result
    }

    /// Full web client context matching YouTube.js Session.#buildContext for WEB client.
}
