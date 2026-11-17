#if os(macOS)
import AppKit
import XCTest
@testable import App

/// The Settings window by keyboard alone: ⌘F to the search, typing, ↑ ↓ through the results and
/// Return to open one, Esc to clear it; Tab between the search and the panes; ↑ ↓ through the
/// panes; ⌘[ back from a page.
@MainActor
final class SettingsKeyboardTests: XCTestCase {
    private var driver: SettingsDriver?

    override func tearDown() async throws {
        driver?.close()
        driver = nil
    }

    private func open(_ navigation: SettingsNavigation = SettingsNavigation()) async throws -> SettingsDriver {
        let opened = try await SettingsDriver.open(navigation)
        driver = opened
        return opened
    }

    func testCommandFPutsTheKeyboardInTheSearch() async throws {
        let settings = try await open()
        XCTAssertFalse(settings.isSearchFocused)
        await settings.press("f", keyCode: 3, modifiers: .command)
        await settings.expect("the search has the keyboard") { settings.isSearchFocused }
        await settings.type("bell")
        await settings.expect("what is typed goes in it") { settings.searchField?.stringValue == "bell" }
    }

    func testTabMovesBetweenTheSearchAndThePanes() async throws {
        let settings = try await open()
        await settings.click(settings.searchField)
        XCTAssertTrue(settings.isSearchFocused)
        await settings.pressTab()
        await settings.expect("Tab leaves the search for the panes") { !settings.isSearchFocused }
        await settings.pressDown()
        await settings.expect("↓ there moves to the next pane") { settings.navigation.pane == .terminal }
        await settings.pressTab()
        await settings.expect("Tab comes back to the search") { settings.isSearchFocused }
        await settings.pressTab(backward: true)
        await settings.expect("⇧Tab goes back to the panes") { !settings.isSearchFocused }
        await settings.pressTab(backward: true)
        await settings.expect("and ⇧Tab to the search again") { settings.isSearchFocused }
    }

    func testArrowsMoveThroughThePanes() async throws {
        let settings = try await open()
        await settings.click(settings.sidebarItems.first)
        XCTAssertEqual(settings.navigation.pane, .appearance)
        await settings.pressDown()
        await settings.pressDown()
        await settings.expect("two panes down") { settings.navigation.pane == .keyboard }
        await settings.pressUp()
        await settings.expect("one back up") { settings.navigation.pane == .terminal }
    }

    func testReturnOpensTheTopResult() async throws {
        let settings = try await open()
        await settings.click(settings.searchField)
        await settings.type("blink")
        await settings.pump(0.3)
        await settings.pressReturn()
        await settings.expect("Cursor Blink's pane opens") { settings.navigation.pane == .terminal }
    }

    /// ↓ and ↑ pick a result while the keyboard stays in the search; Return opens the picked one.
    func testArrowsPickAResultAndReturnOpensIt() async throws {
        let settings = try await open(SettingsNavigation(pane: .about))
        await settings.click(settings.searchField)
        await settings.type("dim")
        await settings.pump(0.3)
        XCTAssertEqual(SettingsIndex.search("dim").map(\.section.pane), [.appearance, .terminal])
        await settings.pressDown()
        await settings.pressDown()
        await settings.pressUp()
        await settings.pressDown()
        XCTAssertTrue(settings.isSearchFocused, "typing more still refines the query")
        await settings.pressReturn()
        await settings.expect("the second result, Unfocused Pane Opacity, opens") { settings.navigation.pane == .terminal }
    }

    func testEscapeClearsTheSearchAndBringsThePanesBack() async throws {
        let settings = try await open()
        await settings.click(settings.searchField)
        await settings.type("font")
        await settings.expect("results replace the panes") { settings.sidebarItems.count < SettingsPane.allCases.count }
        await settings.pressEscape()
        await settings.expect("the query is gone") { settings.searchField?.stringValue == "" }
        await settings.expect("the panes are back") { settings.sidebarItems.count == SettingsPane.allCases.count }
    }

    func testCommandLeftBracketGoesBackFromAPage() async throws {
        let settings = try await open()
        await settings.click(settings.controls(.focusable).first)
        await settings.expect("the theme page opens") { settings.navigation.path == [.theme] }
        await settings.press("[", keyCode: 33, modifiers: .command)
        await settings.expect("back at Appearance") { settings.navigation.path.isEmpty }
    }

    /// ⌘W and ⌘F typed in Settings are Settings' own: ⌘W closes it, ⌘F searches it, and the
    /// terminal window behind keeps its panes and opens no find bar.
    func testCommandWAndCommandFInSettingsLeaveTheTerminalWindowAlone() async throws {
        let terminal = try await WorkspaceDriver.start()
        defer { terminal.close() }
        let settings = try await open(SettingsNavigation(pane: .terminal))
        let workspace = try terminal.workspace
        let tabs = workspace.session.tabs.count
        let panes = workspace.session.activeTab?.root.panes.count
        await settings.press("f", keyCode: 3, modifiers: .command)
        await settings.expect("⌘F went to Settings' search") { settings.isSearchFocused }
        XCTAssertFalse(terminal.model.isSearchShown, "⌘F opened no find bar behind Settings")
        let closed = closeWatch(settings.window)
        await settings.press("w", keyCode: 13, modifiers: .command)
        await settings.pump(0.5)
        XCTAssertEqual(workspace.session.activeTab?.root.panes.count, panes, "⌘W closed no pane behind Settings")
        XCTAssertEqual(workspace.session.tabs.count, tabs)
        XCTAssertTrue(closed.isClosed, "⌘W closed Settings")
    }

    func testCloseTabInSettingsClosesSettingsNotATerminalTab() async throws {
        let terminal = try await WorkspaceDriver.start()
        defer { terminal.close() }
        let settings = try await open()
        let workspace = try terminal.workspace
        let tabs = workspace.session.tabs.count
        let closed = closeWatch(settings.window)
        await settings.press("w", keyCode: 13, modifiers: [.command, .option])
        await settings.pump(0.5)
        XCTAssertEqual(workspace.session.tabs.count, tabs, "⌥⌘W closed no tab behind Settings")
        XCTAssertTrue(closed.isClosed, "⌥⌘W closed Settings")
    }

    private final class CloseWatch {
        var isClosed = false
        var token: NSObjectProtocol?
        deinit { token.map(NotificationCenter.default.removeObserver) }
    }

    private func closeWatch(_ window: NSWindow) -> CloseWatch {
        let watch = CloseWatch()
        watch.token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak watch] _ in
            watch?.isClosed = true
        }
        return watch
    }
}
#endif
