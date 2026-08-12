import UIKit

// MARK: - Page structure
//
// The settings tree: a root page of category rows, each pushing the same
// view controller with a different `page`. Rows, cells and pickers are
// shared — only the section layout differs per page.

extension SettingsViewController {
    var pageTitle: String { Self.title(for: page) }

    var sections: [Section] {
        switch page {
        case .root:
            return rootSections
        case .appearance:
            return appearanceSections
        case .language:
            return languageSections
        case .playback:
            return playbackSections
        case .shorts:
            return shortsSections
        case .sponsorBlock:
            return sponsorBlockSections
        case .cache:
            return cacheSections
        case .debug:
            return debugSections
        }
    }

    /// Category rows push a child page; `.notificationSettings` and
    /// `.feedback` keep their existing handlers.
    private var rootSections: [Section] {
        [
            Section(
                header: nil,
                footer: nil,
                rows: [
                    .pageAppearance, .pageLanguage,
                    .pagePlayback, .pageShorts,
                    .notificationSettings, .pageSponsorBlock,
                    .pageCache, .pageDebug
                ]
            ),
            Section(
                header: nil,
                footer: appVersionFooter,
                rows: [.feedback, .support]
            )
        ]
    }

    private var appearanceSections: [Section] {
        var themeRows: [Row] = [.theme]
        if showsAutoHours {
            themeRows.append(contentsOf: [.autoDarkStart, .autoDarkEnd])
        }
        return [
            Section(header: nil, footer: themeFooter, rows: themeRows + [.appIcon]),
            Section(
                header: "settings.section.home".localized,
                footer: "settings.footer.home".localized,
                rows: [.homeLayout, .defaultTab]
            )
        ]
    }

    private var languageSections: [Section] {
        [
            Section(
                header: nil,
                footer: "settings.footer.language".localized,
                rows: [.appLanguage, .region]
            )
        ]
    }

    private var playbackSections: [Section] {
        var autoDubRows: [Row] = [.autoDubEnabled]
        if AutoDubPreference.isEnabled {
            autoDubRows.append(contentsOf: [.autoDubLanguage, .autoDubIgnoreAI])
        }
        return [
            Section(
                header: nil,
                footer: "settings.footer.playback".localized,
                rows: [
                    .quality, .backgroundPlayback, .pipEnabled,
                    .autoZoomToFill, .hideStatusBar,
                    .autoplayEnabled, .autoplayMixEnabled
                ]
            ),
            Section(
                header: "settings.section.ryd".localized,
                footer: "settings.footer.ryd".localized,
                rows: [.rydEnabled]
            ),
            Section(
                header: "settings.section.autoDub".localized,
                footer: "settings.footer.autoDub".localized,
                rows: autoDubRows
            )
        ]
    }

    private var shortsSections: [Section] {
        var rows: [Row] = [.showShorts]
        if UserDefaults.standard.bool(forKey: UserDefaultsKeys.Feed.showShorts) {
            rows.append(contentsOf: [.shortsPlayer, .shortsGrouping])
        }
        return [
            Section(
                header: nil,
                footer: "settings.footer.shorts".localized,
                rows: rows
            )
        ]
    }

    private var sponsorBlockSections: [Section] {
        var rows: [Row] = [.sponsorBlockEnabled]
        if SponsorBlockService.enabled {
            rows.append(.sponsorBlockSettings)
        }
        return [
            Section(
                header: nil,
                footer: SponsorBlockService.enabled
                    ? SponsorBlockService.attributionText
                    : nil,
                rows: rows
            )
        ]
    }

    private var cacheSections: [Section] {
        var rows: [Row] = [.persistCache]
        if AppCache.persistenceEnabled {
            rows.append(.feedCacheDays)
        }
        rows.append(.imageCacheEnabled)
        if ThumbnailImageView.cachingEnabled {
            rows.append(.imageCacheDays)
        }
        rows.append(.clearCache)
        return [Section(header: nil, footer: nil, rows: rows)]
    }

    private var debugSections: [Section] {
        [
            Section(
                header: nil,
                footer: "settings.footer.debug".localized,
                rows: [
                    .playbackSource, .solverEndpoint,
                    .mainThreadWatchdog, .shareLog
                ]
            )
        ]
    }

    // MARK: Category rows

    static func title(for page: Page) -> String {
        switch page {
        case .root:
            return "settings.title".localized
        case .appearance:
            return "settings.section.appearance".localized
        case .language:
            return "settings.section.language".localized
        case .playback:
            return "settings.section.playback".localized
        case .shorts:
            return "shorts.shelf.title".localized
        case .sponsorBlock:
            return "settings.section.sponsorblock".localized
        case .cache:
            return "settings.section.cache".localized
        case .debug:
            return "settings.section.debug".localized
        }
    }

    func makePageCell(_ row: Row) -> UITableViewCell? {
        guard let page = childPage(row) else {
            return nil
        }
        return makeDisclosureCell(Self.title(for: page))
    }

    func handlePageSelection(_ row: Row) -> Bool {
        guard let page = childPage(row) else {
            return false
        }
        navigationController?.pushViewController(
            SettingsViewController(page: page),
            animated: true
        )
        return true
    }

    private func childPage(_ row: Row) -> Page? {
        switch row {
        case .pageAppearance:
            return .appearance
        case .pageLanguage:
            return .language
        case .pagePlayback:
            return .playback
        case .pageShorts:
            return .shorts
        case .pageSponsorBlock:
            return .sponsorBlock
        case .pageCache:
            return .cache
        case .pageDebug:
            return .debug
        default:
            return nil
        }
    }
}
