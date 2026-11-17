#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import App

/// The menu bar as a person meets it: every command the app adds is there with its key, no two
/// share a key, each runs without raising, each key does what the menu says, and Keyboard
/// Shortcuts lists every one.
@MainActor
final class MainMenuTests: XCTestCase {
    struct Command {
        let path: [String]
        let item: NSMenuItem

        /// The key as a menu draws it, ⌃⌥⇧⌘ then the key; nil without one.
        var keys: [String]? {
            guard !item.keyEquivalent.isEmpty else { return nil }
            let flags = item.keyEquivalentModifierMask
            var keys: [String] = []
            if flags.contains(.control) { keys.append("⌃") }
            if flags.contains(.option) { keys.append("⌥") }
            if flags.contains(.shift) { keys.append("⇧") }
            if flags.contains(.command) { keys.append("⌘") }
            let named: [String: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\r": "↩", "\u{1B}": "⎋", "\t": "⇥"]
            keys.append(named[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
            return keys
        }

        /// Made by the app's own commands, not one of AppKit's standard items.
        var isAppCommand: Bool {
            item.target.map { String(describing: type(of: $0)).contains("MenuItemCallback") } ?? false
        }
    }

    /// Commands that leave the test's window: a window of their own on screen, a modal alert, a
    /// web page, the update check, or a change to a repository.
    static let leavesTheWindow: Set<String> = [
        "New Window", "Settings…", "Install Command Line Tool…", "Check for Updates…", "New Drawing", "Open in New Window",
        "Run Script", "Open Pull Request on GitHub", "Merge Pull Request…", "Re-run Failed Checks", "Create Pull Request",
        "Archive Worktree", "Close Window",
    ]

    static func commands(in menu: NSMenu, path: [String] = []) -> [Command] {
        menu.update()
        return menu.items.flatMap { item -> [Command] in
            guard !item.isSeparatorItem, !item.isHidden, !item.isSectionHeader else { return [] }
            if let submenu = item.submenu { return commands(in: submenu, path: path + [item.title]) }
            return [Command(path: path + [item.title], item: item)]
        }
    }

    private var menuBar: [Command] {
        get throws { Self.commands(in: try XCTUnwrap(NSApp.mainMenu, "the app's menu bar")) }
    }

    func testFileClosesTheTabAndTheWindow() async throws {
        let driver = try await WindowDriver.start(width: 1180)
        defer { driver.close() }
        let commands = try menuBar
        let closeTab = try XCTUnwrap(commands.first { $0.path == ["File", "Close Tab"] }, "File ▸ Close Tab: \(commands.filter { $0.path.first == "File" }.map(\.path))")
        XCTAssertEqual(closeTab.keys, ["⌥", "⌘", "W"])
        let closeWindow = try XCTUnwrap(commands.first { $0.path == ["File", "Close Window"] }, "File ▸ Close Window")
        XCTAssertEqual(closeWindow.keys, ["⇧", "⌘", "W"])

        let workspace = try driver.workspace
        workspace.apply(.newTab)
        await driver.pump(0.5)
        let shown = try XCTUnwrap(driver.model.currentTab)
        try await driver.press(MenuCommand.closeTab.shortcut)
        await driver.expect("⌥⌘W closes the tab on screen") { !driver.model.groups.tabs.contains(shown) }
        XCTAssertTrue(driver.window.isVisible, "and leaves the window open")
    }

    func testEveryMenuInTheBarHoldsSomething() async throws {
        let driver = try await WindowDriver.start(width: 1180)
        defer { driver.close() }
        let bar = try XCTUnwrap(NSApp.mainMenu, "the app's menu bar")
        let empty = bar.items.filter { item in
            guard !item.isHidden, let submenu = item.submenu else { return false }
            submenu.update()
            return !submenu.items.contains { !$0.isHidden && !$0.isSeparatorItem }
        }
        XCTAssertEqual(empty.map(\.title), [], "menus with nothing in them")
    }

    func testNoTwoCommandsShareAKey() throws {
        var byKey: [[String]: [String]] = [:]
        for command in try menuBar where !command.item.isAlternate {
            guard let keys = command.keys else { continue }
            byKey[keys, default: []].append(command.path.joined(separator: " ▸ "))
        }
        for (keys, paths) in byKey where paths.count > 1 {
            XCTFail("\(keys.joined()) is on \(paths)")
        }
    }

    func testKeyboardShortcutsListsEveryKeyTheMenusHold() throws {
        let listed = ShortcutsSheet.sections.flatMap { ShortcutsSheet.rows($0.entries) }
        let listedKeys = Set(listed.flatMap(\.keys))
        for command in try menuBar where command.isAppCommand {
            guard let keys = command.keys else { continue }
            XCTAssertTrue(listedKeys.contains(keys), "\(command.path.joined(separator: " ▸ ")) (\(keys.joined())) is missing from Keyboard Shortcuts")
        }
    }

    func testEveryKeyKeyboardShortcutsListsIsAnswered() throws {
        let menuKeys = Set(try menuBar.compactMap(\.keys))
        for section in ShortcutsSheet.sections {
            for entry in section.entries {
                for shortcut in entry.shortcuts {
                    let event = try WindowDriver.keyEvent(shortcut)
                    XCTAssertTrue(menuKeys.contains(shortcut.symbols) || WorkspaceShortcuts.action(for: event) != nil,
                                  "\(entry.title) (\(shortcut.symbols.joined())) is listed but nothing answers it")
                }
            }
        }
    }

    /// The terminal answers the app's keys before the menus do (`WorkspaceShortcuts`): each key
    /// it takes runs the command the menu shows for that key.
    func testTheTerminalsKeysRunWhatTheMenusShow() throws {
        for command in try menuBar where command.isAppCommand {
            let item = command.item
            guard let character = item.keyEquivalent.first else { continue }
            var modifiers: EventModifiers = []
            let flags = item.keyEquivalentModifierMask
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            let event = try WindowDriver.keyEvent(KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers))
            guard let action = WorkspaceShortcuts.action(for: event) else { continue }
            XCTAssertEqual(action.title, item.title, "\(command.keys?.joined() ?? "") in a terminal")
        }
    }

    func testKeyboardShortcutsListsEachCommandOnce() {
        let titles = ShortcutsSheet.sections.flatMap { ShortcutsSheet.rows($0.entries).map(\.title) }
        let repeated = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertEqual(Array(repeated), [], "listed more than once")
    }

    func testEveryCommandRunsWithoutRaising() async throws {
        let driver = try await WindowDriver.start(width: 1180)
        defer { driver.close() }
        let showsTabBar = TabPlacement.showsTabBar
        defer { TabPlacement.showsTabBar = showsTabBar }
        let commands = try menuBar.filter { $0.isAppCommand && !Self.leavesTheWindow.contains($0.path.last ?? "") }
        XCTAssertGreaterThan(commands.count, 60, "the app's commands: \(commands.map(\.path))")
        for command in commands {
            try await driver.freshSplitTab()
            guard let menu = command.item.menu else { continue }
            menu.update()
            guard command.item.isEnabled else { continue }
            menu.performActionForItem(at: menu.index(of: command.item))
            await driver.pump(0.3)
            await driver.dismissOverlays()
            if driver.model.isTwoColumns { driver.model.toggleTwoColumns() }
            if !driver.model.isSidebarShown { await driver.showSidebar(true) }
            XCTAssertTrue(driver.window.isVisible, "\(command.path) left the window open")
        }
    }

    // MARK: Keys

    func testEachKeyDoesWhatItsCommandSays() async throws {
        let driver = try await WindowDriver.start(width: 1180)
        defer { driver.close() }
        let model = driver.model
        let workspace = try driver.workspace
        for _ in 0..<3 { workspace.apply(.newTab) }
        await driver.pump(0.5)

        for number in 1...8 {
            guard let ref = model.groups.tab(forShortcut: number) else { continue }
            try await driver.press(WorkspaceAction.selectTab(number).shortcut)
            XCTAssertEqual(model.currentTab, ref, "⌘\(number)")
        }
        let last = model.groups.tabs.last
        try await driver.press(WorkspaceAction.lastTab.shortcut)
        XCTAssertEqual(model.currentTab, last, "⌘9 shows the last tab")
        try await driver.press(WorkspaceAction.selectTab(1).shortcut)
        try await driver.press(WorkspaceAction.nextTab.shortcut)
        XCTAssertEqual(model.currentTab, model.groups.tabs[1], "⇧⌘] shows the next tab")
        try await driver.press(WorkspaceAction.previousTab.shortcut)
        XCTAssertEqual(model.currentTab, model.groups.tabs[0], "⇧⌘[ shows the previous tab")

        func check(_ shortcut: KeyboardShortcut, _ name: String, file: StaticString = #filePath, line: UInt = #line,
                   setUp: Bool = true, did: (WindowDriver.State, WindowDriver.State) -> Bool) async throws {
            if setUp { try await driver.freshSplitTab() }
            let before = driver.state
            let taken = try await driver.press(shortcut)
            XCTAssertTrue(taken, "\(shortcut.symbols.joined()) is taken (\(name))", file: file, line: line)
            await driver.pump(0.3)
            let after = driver.state
            XCTAssertTrue(did(before, after), "\(shortcut.symbols.joined()) \(name): \(before) → \(after)", file: file, line: line)
            await driver.dismissOverlays()
        }
        try await check(WorkspaceAction.newTab.shortcut, "opens a tab") { $1.tabs == $0.tabs + 1 }
        try await check(WorkspaceAction.splitRight.shortcut, "splits right") { $1.panes == $0.panes + 1 }
        try await check(WorkspaceAction.splitDown.shortcut, "splits down") { $1.panes == $0.panes + 1 }
        try await check(WorkspaceAction.closePane.shortcut, "closes the pane") { $1.panes == $0.panes - 1 }
        try await check(MenuCommand.closeTab.shortcut, "closes the tab") { $1.tabs == $0.tabs - 1 }
        // The menu bar's History items follow the window SwiftUI last reported focused, which a
        // test window never is; in a terminal the app takes the key itself.
        let closed = driver.state
        let reopened = try await driver.pressInTerminal(WorkspaceAction.reopenClosedTab.shortcut)
        XCTAssertTrue(reopened, "⇧⌘T in a terminal")
        XCTAssertEqual(driver.state.tabs, closed.tabs + 1, "⇧⌘T reopens the tab")
        try await check(WorkspaceAction.toggleSidebar.shortcut, "toggles the sidebar") { $1.isSidebarShown != $0.isSidebarShown }
        try await check(WorkspaceAction.toggleSidebar.shortcut, "toggles it back", setUp: false) { $1.isSidebarShown != $0.isSidebarShown }
        try await check(WorkspaceAction.commandPalette.shortcut, "opens the palette") { $1.palette == .commands }
        try await check(WorkspaceAction.commandPaletteGhostty.shortcut, "opens the palette") { $1.palette == .commands }
        try await check(WorkspaceAction.goToTab.shortcut, "finds a tab") { $1.palette == .goToTab }
        try await check(WorkspaceAction.newTabOnHost.shortcut, "asks which host") { $1.palette == .newTabOnHost }
        try await check(WorkspaceAction.splitWithHost.shortcut, "asks which host to split with") { $1.palette == .splitWithHost }
        try await check(WorkspaceAction.shortcuts.shortcut, "lists the shortcuts") { $1.sheet == .shortcuts }
        try await check(WorkspaceAction.links.shortcut, "lists links") { $1.sheet == .links }
        try await check(WorkspaceAction.newAgent.shortcut, "starts an agent") { $1.sheet == .launchAgent }
        try await check(WorkspaceAction.newProject.shortcut, "makes a project") { $1.projects == $0.projects + 1 }
        try await check(WorkspaceAction.inbox.shortcut, "shows the agents") { $1.destination == .inbox }
        try await check(WorkspaceAction.hosts.shortcut, "shows the hosts") { $1.destination == .hosts }
        try await check(WorkspaceAction.find.shortcut, "finds in the pane") { $1.isSearchShown }
        try await check(WorkspaceAction.toggleZoom.shortcut, "zooms the pane") { $1.isZoomed != $0.isZoomed }
        try await check(WorkspaceAction.splitBestFit.shortcut, "splits the pane") { $1.panes == $0.panes + 1 }
        try await check(WorkspaceAction.toggleFloat.shortcut, "floats the pane") { $1.floats == $0.floats + 1 }
        try await check(WorkspaceAction.movePaneToNewTab.shortcut, "moves the pane to a tab") { $1.tabs == $0.tabs + 1 }
    }
}
#endif
