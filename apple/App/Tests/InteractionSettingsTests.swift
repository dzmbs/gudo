import DesignSystem
import SwiftUI
import XCTest
@testable import App

@MainActor
final class InteractionSettingsTests: XCTestCase {
    private var saved: Any?

    override func setUp() async throws {
        saved = UserDefaults.standard.object(forKey: TerminalPreferences.Key.sidebarTextSize)
    }

    override func tearDown() async throws {
        if let saved { UserDefaults.standard.set(saved, forKey: TerminalPreferences.Key.sidebarTextSize) } else {
            UserDefaults.standard.removeObject(forKey: TerminalPreferences.Key.sidebarTextSize)
        }
    }

    func testSidebarTextSizeAppliesWhileTheAppRuns() async throws {
        UserDefaults.standard.set(TerminalPreferences.SidebarTextSize.large.rawValue, forKey: TerminalPreferences.Key.sidebarTextSize)
        try await waitFor { SidebarSize.shared.size == .large }
        XCTAssertEqual(SidebarFont.icon, DS.Font.sidebar(.large).icon)
        UserDefaults.standard.set(TerminalPreferences.SidebarTextSize.small.rawValue, forKey: TerminalPreferences.Key.sidebarTextSize)
        try await waitFor { SidebarSize.shared.size == .small }
        XCTAssertEqual(SidebarFont.icon, DS.Font.sidebar(.small).icon)
    }

    func testEveryNewSettingCanBeFound() {
        let ids = Set(SettingsIndex.all.map(\.id))
        for id in ["pane-style", "pane-inactive-fade", "pane-active-border", "sidebar-text-size", "toast-position"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        XCTAssertTrue(SettingsIndex.search("toast").contains { $0.id == "toast-position" })
        XCTAssertTrue(SettingsIndex.search("border").contains { $0.id == "pane-active-border" })
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
