#if os(macOS)
import AppKit
import DesignSystem
import PaneLayout
import SwiftUI
import TerminalRenderer
import XCTest
@testable import App

/// The app's window in an off-screen window, driven the way a person drives it: clicks and keys
/// sent through the window and the menu bar, menus opened and chosen from. While it is open an
/// Objective-C exception AppKit reports fails the test (`ExceptionTrap`).
@MainActor
final class WindowDriver {
    /// Off screen, and key as far as its own views can tell: a test never activates the app,
    /// and a window that is not key takes a first click on its content only to become key.
    final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    enum MouseButton {
        case left, right, middle
    }

    /// Where each strip chip is, in its strip's own hosting view.
    @MainActor
    final class ChipFrames {
        var frames: [TabRef: CGRect] = [:]
    }

    let model: WindowModel
    let window: NSWindow
    let menus = OpenedMenus()
    private let chips: ChipFrames
    private let trap = ExceptionTrap.install()

    private init(model: WindowModel, window: NSWindow, chips: ChipFrames) {
        self.model = model
        self.window = window
        self.chips = chips
    }

    /// A started mock window `width` wide, with its first pane up.
    static func start(width: CGFloat, height: CGFloat = 700) async throws -> WindowDriver {
        try XCTSkipUnless(LaunchOptions.mock, "renders the mock workspace")
        let driver = open(width: width, height: height)
        let model = driver.model
        _ = await driver.wait { model.workspace?.focusedPane != nil }
        // The mock hosts and the settings outlive a window: one tab and the strip on to start
        // from, whatever came before.
        TabPlacement.showsTabBar = true
        model.closeTabs(Array(model.groups.tabs.dropFirst()), undoable: false)
        model.recentlyClosed.removeAll()
        await driver.pump(1.0)
        return driver
    }

    /// A window on the paired host `hostId` with the host's own tools (files, ports, links),
    /// sidebar hidden, its first shell live and holding the keyboard.
    static func start(host hostId: String, width: CGFloat = 1180, height: CGFloat = 760) async throws -> WindowDriver {
        let driver = open(width: width, height: height, liveTools: true)
        let model = driver.model
        model.isSidebarShown = false
        model.show(.host(hostId))
        // On screen behind another app's window: an offscreen test window's scene is in the background.
        model.isOnScreen = true
        await driver.expect("a live shell on the host", timeout: 20) {
            guard let workspace = model.workspace, workspace.hostId == hostId, let id = workspace.focusedPane,
                  let pane = workspace.pane(id) else { return false }
            return pane.connection == .live && pane.view.window != nil
        }
        if let workspace = model.workspace, let id = workspace.focusedPane, let pane = workspace.pane(id) {
            driver.window.makeFirstResponder(pane.view)
        }
        return driver
    }

    private static func open(width: CGFloat, height: CGFloat, liveTools: Bool = false) -> WindowDriver {
        let model = WindowModel(app: .shared, liveTools: liveTools)
        model.start()
        let frame = NSRect(x: -30000, y: -30000, width: width, height: height)
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let chips = ChipFrames()
        let controller = NSHostingController(rootView: ThemedRoot {
            WindowContent(request: nil, model: model)
                .environment(AppModel.shared)
                .environment(\.tabChipFrames) { ref, frame in chips.frames[ref] = frame }
        })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return WindowDriver(model: model, window: window, chips: chips)
    }

    func close() {
        model.isPaletteShown = false
        model.sheet = nil
        window.close()
        model.close()
        trap.uninstall()
    }

    var workspace: Workspace {
        get throws { try XCTUnwrap(model.workspace, "the mock workspace") }
    }

    func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Waits for `condition`, up to `timeout`; whether it came true.
    func wait(timeout: Double = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() {
            if Date.now > deadline { return false }
            await pump(0.05)
        }
        return true
    }

    /// Fails with `message` unless `condition` comes true within `timeout`.
    func expect(_ message: @autoclosure () -> String, timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line,
                until condition: () -> Bool) async {
        if await !wait(timeout: timeout, until: condition) { XCTFail(message(), file: file, line: line) }
    }

    /// Shows or hides the sidebar and lets the bar settle into its new items.
    func showSidebar(_ shown: Bool) async {
        model.isSidebarShown = shown
        await pump(1.5)
    }

    /// What the window shows, for telling what a control did.
    struct State: CustomStringConvertible {
        var tabs: Int
        var tab: TabRef?
        var panes: Int
        var floats: Int
        var isZoomed: Bool
        var sheet: SheetRoute?
        var palette: PaletteMode?
        var isSearchShown: Bool
        var isMixed: Bool
        var destination: Destination
        var isTwoColumns: Bool
        var isSidebarShown: Bool
        var host: String
        var renaming: TabId?
        var projects: Int

        var description: String {
            "tabs \(tabs) tab \(tab.map(\.description) ?? "-") panes \(panes) floats \(floats) zoomed \(isZoomed) sheet \(sheet?.rawValue ?? "-") "
                + "palette \(palette.map { "\($0)" } ?? "-") search \(isSearchShown) mixed \(isMixed) \(destination) two columns \(isTwoColumns) "
                + "sidebar \(isSidebarShown) host \(host) renaming \(renaming.map { "\($0)" } ?? "-") projects \(projects)"
        }
    }

    var state: State {
        let workspace = model.workspace
        let tab = workspace?.session.activeTab
        return State(
            tabs: model.groups.tabs.count, tab: model.currentTab,
            panes: model.activeMixed?.leaves.count ?? tab?.root.panes.count ?? 0,
            floats: workspace?.session.floats.count ?? 0, isZoomed: tab?.zoomed != nil,
            sheet: model.sheet, palette: model.isPaletteShown ? model.paletteMode : nil,
            isSearchShown: model.isSearchShown, isMixed: model.activeMixed != nil, destination: model.destination,
            isTwoColumns: model.isTwoColumns, isSidebarShown: model.isSidebarShown, host: model.currentGroupId,
            renaming: workspace?.renamingTab, projects: model.projects.count)
    }

    /// Back to the terminal with nothing over it.
    func dismissOverlays() async {
        model.isPaletteShown = false
        model.paletteMode = .commands
        model.sheet = nil
        model.isSearchShown = false
        model.isHostSwitcherShown = false
        model.destination = .terminal
        model.workspace?.renamingTab = nil
        model.git.isCheckoutPromptShown = false
        model.endTabSelection()
        await pump(0.4)
    }

    /// A fresh tab of two panes, on screen; the oldest tabs close past a dozen.
    func freshSplitTab(file: StaticString = #filePath, line: UInt = #line) async throws {
        let workspace = try self.workspace
        if model.groups.tabs.count > 12 { model.closeTabs(Array(model.groups.tabs.prefix(8)), undoable: false) }
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        let tab = try XCTUnwrap(workspace.session.tabs.first { !before.contains($0.id) }, "a new tab", file: file, line: line)
        model.focus(TabRef(hostId: workspace.groupId, tab: tab.id))
        workspace.split(.horizontal)
        _ = await wait { self.state.panes == 2 && !self.state.isMixed }
        await pump(0.3)
    }

    // MARK: Title bar

    var toolbarLabels: [String] { (window.toolbar?.items ?? []).map(\.label) }

    func toolbarItemView(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.label == label }, "\(label) in \(toolbarLabels)", file: file, line: line)
        return try XCTUnwrap(item.view, "\(label) has a view", file: file, line: line)
    }

    /// Clicks the middle of the bar's item named `label`, which must take the click itself.
    func click(toolbarItem label: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let view = try toolbarItemView(label, file: file, line: line)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let frameView = try XCTUnwrap(window.contentView?.superview)
        let hit = frameView.hitTest(frameView.convert(point, from: nil))
        XCTAssertTrue(hit?.isDescendant(of: view) ?? false, "\(label) takes its own clicks: \(String(describing: hit))", file: file, line: line)
        try await click(at: point)
    }

    /// The bar's item just before Split: the host button, which names no label of its own.
    func hostItemView(file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        let items = try XCTUnwrap(window.toolbar?.items, file: file, line: line)
        let split = try XCTUnwrap(items.firstIndex { $0.label == "Split" }, "Split in \(toolbarLabels)", file: file, line: line)
        return try XCTUnwrap(items[split - 1].view, "the host item has a view", file: file, line: line)
    }

    func click(view: NSView) async throws {
        try await click(at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }

    // MARK: Tab strip

    /// The strip's own hosting view in the title bar (sidebar hidden).
    func stripHost(file: StaticString = #filePath, line: UInt = #line) throws -> NSView {
        let strip = (window.toolbar?.items ?? []).compactMap(\.view).first { Self.descendant(of: $0) { $0 is NSScrollView } != nil }
        let host = strip.flatMap { Self.descendant(of: $0) { $0 is NSHostingView<AnyView> } }
        return try XCTUnwrap(host, "the strip is in the bar: \(toolbarLabels)", file: file, line: line)
    }

    static func descendant(of view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        if matches(view) { return view }
        for subview in view.subviews {
            if let found = descendant(of: subview, where: matches) { return found }
        }
        return nil
    }

    /// Waits for every tab's chip to be laid out in the strip.
    func waitForChips(file: StaticString = #filePath, line: UInt = #line) async {
        await expect("every tab has a chip: \(model.groups.tabs)", file: file, line: line) {
            self.model.groups.tabs.allSatisfy { self.chips.frames[$0] != nil }
        }
    }

    /// A point in the window `inset` from the leading edge of `ref`'s chip (its middle when nil).
    /// The strip's own hosting view reports its chips in the window's coordinates.
    func chipPoint(_ ref: TabRef, inset: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> NSPoint {
        let root = try XCTUnwrap(window.contentView, file: file, line: line)
        let frame = try XCTUnwrap(chips.frames[ref], "\(ref) has a chip", file: file, line: line)
        let x = inset.map { frame.minX + $0 } ?? frame.midX
        XCTAssertTrue(root.isFlipped, file: file, line: line)
        return root.convert(NSPoint(x: x, y: frame.midY), to: nil)
    }

    /// The strip's +, at its trailing end.
    func newButtonPoint(file: StaticString = #filePath, line: UInt = #line) throws -> NSPoint {
        let host = try stripHost(file: file, line: line)
        return host.convert(NSPoint(x: host.bounds.maxX - DS.Size.tab / 2, y: host.bounds.midY), to: nil)
    }

    /// The shown popover's window, if one is up.
    var popoverWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && String(describing: Swift.type(of: $0)).contains("Popover") }
    }

    // MARK: Mouse

    /// Sent to the window from the run loop, not from the test, so what an action raises is
    /// reported the way the app reports it. The window is never key in a test run: sent to the
    /// app, the press would only be taken to activate it. The release follows a moment later
    /// through the queue, where a control tracking the press reads it; a tap in a scroll view
    /// waits that long to tell a click from a scroll. SwiftUI's tap gestures take a made-up
    /// click only without a click count.
    func click(at point: NSPoint, button: MouseButton = .left, clickCount: Int = 0, in window: NSWindow? = nil) async throws {
        let window = window ?? self.window
        let types: (NSEvent.EventType, NSEvent.EventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        case .middle: (.otherMouseDown, .otherMouseUp)
        }
        nonisolated(unsafe) let press = try Self.mouseEvent(types.0, at: point, in: window, clickCount: clickCount)
        nonisolated(unsafe) let release = try Self.mouseEvent(types.1, at: point, in: window, clickCount: clickCount)
        nonisolated(unsafe) let receiver = window
        // A control tracking the press reads the release from the queue; otherwise it goes to
        // the window as the press did.
        let releaseLater = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                if RunLoop.current.currentMode == .eventTracking {
                    NSApp.postEvent(release, atStart: false)
                } else if button != .left {
                    NSApp.postEvent(release, atStart: false)
                } else {
                    receiver.sendEvent(release)
                }
            }
        }
        RunLoop.main.add(releaseLater, forMode: .common)
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                // Through the app, which makes it the current event: what takes a middle click
                // asks for it while hit testing, and a bar finds a context menu by it. Only a
                // left press would activate the app.
                if button == .left { receiver.sendEvent(press) } else { NSApp.postEvent(press, atStart: false) }
            }
        }
        await pump(0.8)
    }

    static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int = 1) throws -> NSEvent {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
        guard type == .otherMouseDown || type == .otherMouseUp, let cgEvent = event.cgEvent else { return event }
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    // MARK: Keys

    static func keyEvent(_ shortcut: KeyboardShortcut, type: NSEvent.EventType = .keyDown, window: NSWindow? = nil) throws -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        var (characters, keyCode) = Self.characters(of: shortcut.key)
        // The symbol ⇧ types; a letter stays lower case, as a menu names its key.
        if shortcut.modifiers.contains(.shift) {
            let shifted: [String: String] = [
                "]": "}", "[": "{", "/": "?", "=": "+", "-": "_", ",": "<", ".": ">", ";": ":", "'": "\"", "`": "~", "\\": "|",
                "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
            ]
            characters = shifted[characters] ?? characters
        }
        if [Character("\u{F700}"), "\u{F701}", "\u{F702}", "\u{F703}"].contains(shortcut.key.character) {
            flags.formUnion([.numericPad, .function])
        }
        return try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// The characters and virtual key code a US keyboard sends for `key`.
    private static func characters(of key: KeyEquivalent) -> (String, UInt16) {
        let character = key.character
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, "+": 24,
            "\r": 36, "\u{1B}": 53, "\t": 48,
            "\u{F702}": 123, "\u{F703}": 124, "\u{F701}": 125, "\u{F700}": 126,
        ]
        return (String(character), codes[Character(character.lowercased())] ?? 0)
    }

    /// A shortcut pressed with the window key: offered to the window, then to the menu bar's
    /// command with exactly that key, as AppKit offers a key equivalent. Matched by hand: a
    /// made-up event lacks what AppKit reads to tell ⇧⌘P from ⌘P. Whether either took it.
    @discardableResult
    func press(_ shortcut: KeyboardShortcut) async throws -> Bool {
        let event = try Self.keyEvent(shortcut, window: window)
        if window.performKeyEquivalent(with: event) {
            await pump(0.5)
            return true
        }
        guard let item = NSApp.mainMenu.flatMap({ Self.item(for: shortcut, in: $0) }), let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        await pump(0.5)
        return true
    }

    /// A shortcut pressed while a terminal has the keyboard: the app's own key handler takes it
    /// before the menus (`WorkspaceShortcuts`), as for a key window. Whether it did.
    @discardableResult
    func pressInTerminal(_ shortcut: KeyboardShortcut) async throws -> Bool {
        guard window.firstResponder is TerminalView, let workspace = model.workspace,
              let action = WorkspaceShortcuts.action(for: try Self.keyEvent(shortcut, window: window))
        else { return false }
        action.perform(on: workspace, window: model)
        await pump(0.5)
        return true
    }

    /// The enabled menu command whose key is exactly `shortcut`.
    static func item(for shortcut: KeyboardShortcut, in menu: NSMenu) -> NSMenuItem? {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        menu.update()
        for item in menu.items where !item.isHidden {
            if let submenu = item.submenu {
                if let found = self.item(for: shortcut, in: submenu) { return found }
            } else if item.isEnabled, item.keyEquivalent == String(shortcut.key.character),
                      item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == flags {
                return item
            }
        }
        return nil
    }

    /// Keys typed into the window's first responder, each down and up.
    func type(_ shortcut: KeyboardShortcut, in window: NSWindow? = nil) async throws {
        let window = window ?? self.window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            window.sendEvent(try Self.keyEvent(shortcut, type: type, window: window))
        }
        await pump(0.3)
    }

    func type(text: String, in window: NSWindow? = nil) async throws {
        for character in text {
            try await type(KeyboardShortcut(KeyEquivalent(character), modifiers: []), in: window)
        }
    }
}

/// The menus that began tracking. Each is closed again at once, after choosing the item at
/// `choice` (titles from the menu down through its submenus) when one is set.
@MainActor
final class OpenedMenus {
    private(set) var titles: [[String]] = []
    /// Every enabled command of the last menu, as the path of titles that reaches it.
    private(set) var commands: [[String]] = []
    /// What the next menu to open chooses; cleared as it is chosen.
    var choice: [String]?
    private(set) var chosen: [String] = []
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { [weak self] notification in
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            MainActor.assumeIsolated {
                guard let self, let menu, menu.supermenu == nil else { return }
                self.opened(menu)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var last: [String] { titles.last ?? [] }

    /// Read once the menu is up: a context menu names its commands only as it shows them. The
    /// choice is sent after the menu has closed, as AppKit sends it.
    private func opened(_ menu: NSMenu) {
        nonisolated(unsafe) let opened = menu
        let readLater = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                opened.update()
                self.titles.append(opened.items.map(\.title))
                self.commands = Self.commands(in: opened)
                let path = self.choice.flatMap { Self.item(at: $0[...], in: opened) == nil ? nil : $0 }
                self.chosen = path ?? []
                self.choice = nil
                opened.cancelTrackingWithoutAnimation()
                guard let path else { return }
                // Found again once closed: a submenu makes its items afresh as it updates.
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        guard let item = Self.item(at: path[...], in: opened), let owner = item.menu else { return }
                        // A submenu is opened on the way, as the pointer opens it.
                        let isSubmenu = owner !== opened
                        if isSubmenu { owner.delegate?.menuWillOpen?(owner) }
                        owner.performActionForItem(at: owner.index(of: item))
                        if isSubmenu { owner.delegate?.menuDidClose?(owner) }
                    }
                }
            }
        }
        RunLoop.main.add(readLater, forMode: .common)
    }

    private static func commands(in menu: NSMenu) -> [[String]] {
        menu.update()
        return menu.items.flatMap { item -> [[String]] in
            guard item.isEnabled, !item.isHidden, !item.isSeparatorItem, !item.isSectionHeader, !item.title.isEmpty else { return [] }
            guard let submenu = item.submenu else { return [[item.title]] }
            return commands(in: submenu).map { [item.title] + $0 }
        }
    }

    private static func item(at path: ArraySlice<String>, in menu: NSMenu) -> NSMenuItem? {
        guard let title = path.first else { return nil }
        menu.update()
        // "*" stands for the first command there, for lists whose names change (the other tabs).
        let isCommand = { (item: NSMenuItem) in item.isEnabled && !item.isSeparatorItem && !item.isSectionHeader && !item.title.isEmpty }
        guard let item = menu.items.first(where: { title == "*" ? isCommand($0) : $0.title == title }) else { return nil }
        guard path.count > 1 else { return item.isEnabled ? item : nil }
        guard let submenu = item.submenu else { return nil }
        return Self.item(at: path.dropFirst(), in: submenu)
    }
}

/// Fails the running test on any Objective-C exception AppKit catches and reports: raised by an
/// action or a menu in no window, it would otherwise only be logged while the app goes on with
/// a half-handled click.
@MainActor
final class ExceptionTrap {
    private(set) static var reported: [NSException] = []
    private static var original: IMP?
    private static var installs = 0

    static func install() -> ExceptionTrap {
        installs += 1
        if installs == 1, let method = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.reportException(_:))) {
            typealias Report = @convention(c) (NSApplication, Selector, NSException) -> Void
            let previous = method_getImplementation(method)
            original = previous
            let forward = unsafeBitCast(previous, to: Report.self)
            let failing: @convention(block) (NSApplication, NSException) -> Void = { application, exception in
                MainActor.assumeIsolated {
                    reported.append(exception)
                    XCTFail("Objective-C exception \(exception.name.rawValue): \(exception.reason ?? "")\n\(exception.callStackSymbols.prefix(30).joined(separator: "\n"))")
                }
                forward(application, #selector(NSApplication.reportException(_:)), exception)
            }
            method_setImplementation(method, imp_implementationWithBlock(failing))
        }
        return ExceptionTrap()
    }

    func uninstall() {
        Self.installs -= 1
        guard Self.installs == 0, let original = Self.original,
              let method = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.reportException(_:)))
        else { return }
        method_setImplementation(method, original)
        Self.original = nil
    }

    static func clear() { reported = [] }
}
#endif
