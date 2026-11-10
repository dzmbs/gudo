import DesignSystem
import Foundation
import PaneLayout
import TerminalRenderer
import XCTest
@testable import App

/// ⌘+ ⌘- ⌘0 as in Ghostty: the focused pane's own size, never the Settings one.
@MainActor
final class PaneFontZoomTests: XCTestCase {
    private final class Quiet: PaneBackend, @unchecked Sendable {
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
    }

    private var workspace: Workspace!

    override func tearDown() async throws {
        workspace?.close()
        workspace = nil
    }

    /// Panes `first` | `second`, `second` focused, drawn at `settingsSize`.
    private func make(settingsSize: CGFloat = 13) -> (first: PaneId, second: PaneId) {
        var session = Session()
        let first = session.activeTab!.focused
        session.apply(.split(first, .horizontal))
        let second = session.activeTab!.focused
        workspace = Workspace(layout: LocalLayoutStore(session: session)) { _ in Quiet() }
        var appearance = workspace.appearance
        appearance.fontSize = settingsSize
        workspace.appearance = appearance
        return (first, second)
    }

    private func fontSize(_ id: PaneId) -> CGFloat? {
        workspace.pane(id)?.view.surface.fontSize
    }

    func testZoomChangesOnlyTheFocusedPane() {
        let (first, second) = make()
        workspace.changeFocusedFontSize(.increase)
        workspace.changeFocusedFontSize(.increase)
        XCTAssertEqual(fontSize(second), 15)
        XCTAssertEqual(fontSize(first), 13)
        workspace.changeFocusedFontSize(.decrease)
        XCTAssertEqual(fontSize(second), 14)
        XCTAssertEqual(fontSize(first), 13)
    }

    func testResetReturnsToTheSettingsSizeAndLeavesThePreference() {
        let (_, second) = make(settingsSize: 15)
        let stored = UserDefaults.standard.object(forKey: TerminalPreferences.Key.fontSize) as? Double
        workspace.changeFocusedFontSize(.increase)
        XCTAssertEqual(fontSize(second), 16)
        workspace.changeFocusedFontSize(.reset)
        XCTAssertEqual(fontSize(second), 15)
        XCTAssertEqual(UserDefaults.standard.object(forKey: TerminalPreferences.Key.fontSize) as? Double, stored)
    }

    /// A zoomed pane keeps its own size through a Settings change, as a Ghostty surface does
    /// until reset; the others follow Settings.
    func testASettingsChangeReachesPanesWithoutAZoom() {
        let (first, second) = make()
        workspace.changeFocusedFontSize(.increase)
        var appearance = workspace.appearance
        appearance.fontSize = 18
        workspace.appearance = appearance
        XCTAssertEqual(fontSize(first), 18)
        XCTAssertEqual(fontSize(second), 14)
        workspace.changeFocusedFontSize(.reset)
        XCTAssertEqual(fontSize(second), 18)
    }

    func testASplitFromAZoomedPaneStartsAtItsSize() throws {
        let (first, second) = make()
        workspace.changeFocusedFontSize(.increase)
        workspace.changeFocusedFontSize(.increase)
        workspace.split(.vertical)
        let third = try XCTUnwrap(workspace.focusedPane)
        XCTAssertFalse([first, second].contains(third))
        XCTAssertEqual(fontSize(third), 15)
        XCTAssertEqual(fontSize(first), 13)
    }

    func testASplitFromAPaneWithoutAZoomFollowsSettings() throws {
        _ = make()
        workspace.split(.vertical)
        let third = try XCTUnwrap(workspace.focusedPane)
        var appearance = workspace.appearance
        appearance.fontSize = 17
        workspace.appearance = appearance
        XCTAssertEqual(fontSize(third), 17)
    }
}
