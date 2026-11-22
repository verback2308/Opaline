import UIKit

// MARK: - Software AV1 (beta)

extension SettingsViewController {
    /// The quality rows, plus the software AV1 switch on devices that have no
    /// AV1 hardware — the only ones it means anything on.
    var qualitySection: Section {
        guard !AV1Support.isHardwareSupported else {
            return Section(
                header: "settings.section.videoQuality".localized,
                footer: nil,
                rows: [.quality, .qualityCellular]
            )
        }
        return Section(
            header: "settings.section.videoQuality".localized,
            footer: "settings.footer.softwareAV1".localized,
            rows: [.quality, .qualityCellular, .softwareAV1]
        )
    }

    func makeSoftwareAV1Cell() -> UITableViewCell {
        makeToggleCell(
            "settings.row.softwareAV1".localized,
            isOn: AV1Support.isSoftwarePreferred
        ) { [weak self] isOn in
            UserDefaults.standard.set(isOn, forKey: UserDefaultsKeys.Playback.softwareAV1)
            // 1440p joins or leaves the quality options; a stored 1440p the
            // ladder no longer offers falls back to the default.
            let keys = [
                UserDefaultsKeys.VideoQuality.selected,
                UserDefaultsKeys.VideoQuality.selectedCellular
            ]
            for key in keys where !isOn && UserDefaults.standard.string(forKey: key) == "1440p" {
                UserDefaults.standard.removeObject(forKey: key)
            }
            self?.reloadSection(containing: .softwareAV1)
        }
    }
}
