import Foundation

/// Centralized `@AppStorage` key names so screens that share a setting
/// (e.g. Settings and Firmware) can't drift apart via a typo.
enum AppStorageKeys {
    static let appearance = "podium.appearance"
    static let confirmBeforeDeletingFirmware = "podium.confirmBeforeDeletingFirmware"
    static let showDeveloperSettings = "podium.showDeveloperSettings"
    static let showFrameRate = "podium.showFrameRate"
}
