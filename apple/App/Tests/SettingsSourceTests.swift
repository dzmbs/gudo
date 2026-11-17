import XCTest

/// What every Settings screen is written with: plain copy without long dashes, and text in the
/// theme's own colours (the system's secondary and tertiary inks fall under 4.5:1 on a themed
/// page).
final class SettingsSourceTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")

    private static let settingsFiles = [
        "Views/SettingsView.swift", "Views/SettingsSearch.swift", "Views/PanesSettings.swift", "Views/ThemePair.swift",
        "Views/ThemePicker.swift", "Views/AgentToolsSettings.swift", "Views/PowerSettings.swift",
        "Views/NetworkSettingsSection.swift", "Views/ReplaySettingsSection.swift", "Views/ThisMacSettingsSection.swift",
        "Views/AccountsSettings.swift", "Git/GitSettingsSection.swift", "Voice/VoiceSettingsSection.swift",
        "Notifications/NotificationPrefsSection.swift", "Security/AppLockSection.swift", "Askpass/PasswordsSection.swift",
        "Screens/SSHKeysView.swift", "Multiplayer/DevicesViews.swift", "Screens/BrowserStartPage.swift",
        "Panes/FileLinks.swift", "Panes/PaneLinks.swift",
    ]

    private func matches(_ pattern: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        return try Self.settingsFiles.flatMap { file -> [String] in
            let source = try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
            return source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { number, line in
                let text = String(line)
                return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil ? nil : "\(file):\(number + 1)"
            }
        }
    }

    func testSettingsCopyHasNoLongDashes() throws {
        XCTAssertEqual(try matches("[\u{2014}\u{2013}]"), [])
    }

    func testSettingsTextTakesTheThemesColours() throws {
        XCTAssertEqual(try matches(#"\.(primary|secondary|tertiary)\b"#), [])
    }
}
