import Foundation

/// UI languages the app ships `.lproj` bundles for. Adding a language =
/// adding its case + a translated `Localizable.strings`, worded from the
/// official YouTube app's own `.lproj` for that language (see the
/// Localization section in AGENTS.md). RTL languages are deferred until a
/// leading/trailing constraint audit.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case russian = "ru"
    case ukrainian = "uk"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case japanese = "ja"
    case portuguese = "pt"
    case polish = "pl"
    case turkish = "tr"
    case vietnamese = "vi"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"

    /// The user's in-app override, nil = follow the system language.
    static var override: AppLanguage? {
        get {
            let stored = UserDefaults.standard.string(
                forKey: UserDefaultsKeys.Localization.appLanguage
            )
            return stored.flatMap(AppLanguage.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(
                newValue?.rawValue,
                forKey: UserDefaultsKeys.Localization.appLanguage
            )
            LocalizationManager.shared.reload()
        }
    }

    /// The effective UI language: the override, else the closest supported
    /// match to the system language, else English.
    static var effective: AppLanguage {
        if let override {
            return override
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if let lang = AppLanguage(rawValue: preferred) {
            return lang
        }
        let parts = preferred.split(separator: "-")
        if parts.count >= 2 {
            let withoutRegion = parts.prefix(2).joined(separator: "-")
            if let lang = AppLanguage(rawValue: withoutRegion) {
                return lang
            }
        }
        let langCode = String(preferred.prefix(2))
        return AppLanguage(rawValue: langCode) ?? .english
    }
}

// MARK: - Display names

extension AppLanguage {
    /// Native-script name for the settings picker.
    var displayName: String {
        switch self {
        case .english:
            "English"
        case .russian:
            "Русский"
        case .ukrainian:
            "Українська"
        case .german:
            "Deutsch"
        case .spanish:
            "Español"
        case .french:
            "Français"
        case .italian:
            "Italiano"
        case .japanese:
            "日本語"
        case .portuguese:
            "Português"
        case .polish:
            "Polski"
        case .turkish:
            "Türkçe"
        case .vietnamese:
            "Tiếng Việt"
        case .chineseSimplified:
            "简体中文"
        case .chineseTraditional:
            "繁體中文"
        }
    }
}
