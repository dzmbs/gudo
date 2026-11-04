#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import App

@MainActor
final class TabMenuTests: XCTestCase {
    func testTabActionsKeepTheirTitlesUnderIconOnlyChrome() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "uses the mock workspace")
        let model = WindowModel(app: .shared)
        model.start()
        defer { model.close() }
        let deadline = Date.now.addingTimeInterval(10)
        while model.workspace?.session.activeTab == nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let workspace = try XCTUnwrap(model.workspace)
        let tab = try XCTUnwrap(workspace.session.activeTab)
        let menu = NSHostingMenu(rootView: TabMenu(tab: tab, workspace: workspace)
            .environment(model)
            .labelStyle(.iconOnly))
        menu.update()
        XCTAssertTrue(menu.items.contains { $0.title == "Rename…" }, "\(menu.items.map(\.title))")
        XCTAssertTrue(menu.items.contains { $0.title == "Close Tab" }, "\(menu.items.map(\.title))")
        XCTAssertFalse(menu.items.contains { !$0.isSeparatorItem && $0.title.isEmpty })
    }
}
#endif
