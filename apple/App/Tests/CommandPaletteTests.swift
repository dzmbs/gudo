#if os(macOS)
import AppKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// The command palette as a person drives it: opened by its button and its keys, searched by
/// typing, a command of each kind run with Return, closed with Esc or ⌘., and every key it shows
/// beside a command a key that works.
@MainActor
final class CommandPaletteTests: XCTestCase {
    private let escape = KeyboardShortcut(.escape, modifiers: [])
    private let enter = KeyboardShortcut(.return, modifiers: [])

    func testItOpensByItsButtonAndKeysAndClosesByEscapeAndCommandPeriod() async throws {
        let driver = try await WindowDriver.start(width: 1180)
        defer { driver.close() }
        let model = driver.model
        try await driver.click(toolbarItem: "Command Palette")
        XCTAssertTrue(model.isPaletteShown, "the button opens it")
        try await driver.type(escape)
        await driver.expect("Esc closes it") { !model.isPaletteShown }

        try await driver.press(WorkspaceAction.commandPalette.shortcut)
        XCTAssertTrue(model.isPaletteShown, "⌘K opens it")
        try await driver.press(WorkspaceAction.commandPalette.shortcut)
        XCTAssertFalse(model.isPaletteShown, "⌘K again closes it")

        try await driver.press(WorkspaceAction.commandPaletteGhostty.shortcut)
        XCTAssertTrue(model.isPaletteShown, "⇧⌘P opens it")
        await driver.expect("the palette's field has the keyboard") { driver.window.firstResponder is NSTextView }
        try await driver.type(KeyboardShortcut(".", modifiers: .command))
        await driver.expect("⌘. closes it") { !model.isPaletteShown }
    }

    /// Opens the palette with ⌘K until its field holds the keyboard. In a test window, never
    /// truly key, every other opening can leave the keyboard with the window itself.
    private func openPalette(in driver: WindowDriver) async throws {
        for _ in 0..<3 {
            await driver.dismissOverlays()
            try await driver.press(WorkspaceAction.commandPalette.shortcut)
            XCTAssertTrue(driver.model.isPaletteShown, "⌘K opens the palette")
            if await driver.wait(timeout: 2, until: { driver.window.firstResponder is NSTextView }) { return }
        }
        XCTFail("the palette's field never took the keyboard: \(String(describing: driver.window.firstResponder))")
    }

    /// Types `query` into a fresh palette and runs the first result with Return.
    private func run(_ query: String, in driver: WindowDriver) async throws {
        try await openPalette(in: driver)
        try await driver.type(text: query)
        try await driver.type(enter)
        await driver.pump(0.4)
    }

    func testACommandOfEachKindRunsFromWhatIsTyped() async throws {
        let driver = try await WindowDriver.start(width: 1180)
        defer { driver.close() }
        let model = driver.model
        let workspace = try driver.workspace

        try await driver.freshSplitTab()
        var before = driver.state
        try await run("Split Right", in: driver)
        XCTAssertEqual(driver.state.panes, before.panes + 1, "Terminal ▸ Split Right")
        XCTAssertFalse(model.isPaletteShown, "running a command closes the palette")

        before = driver.state
        try await run("Float Pane", in: driver)
        XCTAssertEqual(driver.state.floats, before.floats + 1, "Pane ▸ Float Pane")

        try await run("Keyboard Shortcuts", in: driver)
        XCTAssertEqual(model.sheet, .shortcuts, "Go ▸ Keyboard Shortcuts")

        let named = try XCTUnwrap(model.groups.tabs.first, "a tab to find")
        workspace.apply(.rename(named.tab, "release notes"))
        try await driver.freshSplitTab()
        try await run("release notes", in: driver)
        XCTAssertEqual(model.currentTab, named, "Tabs ▸ release notes")

        let closing = try XCTUnwrap(model.currentTab)
        workspace.apply(.rename(closing.tab, "scratch build"))
        model.closeCurrentTab()
        await driver.pump(0.4)
        before = driver.state
        try await run("scratch build", in: driver)
        XCTAssertEqual(driver.state.tabs, before.tabs + 1, "Recently Closed ▸ scratch build")

        let other = model.hosts.hosts.first { host in !host.isLocal && model.groups.group(host.id) == nil }
        if let other {
            model.destination = .inbox
            try await run("Connect to \(other.name)", in: driver)
            XCTAssertEqual(model.destination, .terminal, "Hosts ▸ Connect to \(other.name)")
        }

        try await openPalette(in: driver)
        try await driver.type(text: "/")
        XCTAssertEqual(model.paletteMode, .workflows, "/ lists the workflows")
        try await driver.type(KeyboardShortcut(.delete, modifiers: []))
        XCTAssertEqual(model.paletteMode, .commands, "⌫ goes back to the commands")
    }

    func testEveryKeyItShowsIsAKeyThatWorks() async throws {
        let driver = try await WindowDriver.start(width: 1180)
        defer { driver.close() }
        let workspace = try driver.workspace
        try await driver.freshSplitTab()
        workspace.apply(.toggleZoom)
        driver.model.closeCurrentTab()
        await driver.pump(0.4)
        let menuKeys = Set(MainMenuTests.commands(in: try XCTUnwrap(NSApp.mainMenu)).compactMap(\.keys))
        let shown = PaletteCommands.all(workspace: workspace, model: driver.model).filter { $0.shortcut != nil }
        XCTAssertGreaterThan(shown.count, 10)
        for command in shown {
            let keys = try XCTUnwrap(command.shortcut)
            // "/" is typed into the palette itself.
            if keys == ["/"] { continue }
            XCTAssertTrue(menuKeys.contains(keys), "\(command.title) shows \(keys.joined()), which no command answers")
        }
    }
}
#endif
