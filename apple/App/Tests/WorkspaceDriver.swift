#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// A mock window off screen, driven the way a person drives it: clicks, drags and keys sent
/// through the window to whatever its hit test and first responder find. Settings the window
/// writes as it is used are put back when it closes (the test host shares its defaults with the
/// development app).
///
/// A test never activates the app, so while a driver is open the app answers that it is active:
/// AppKit gives the first click in an inactive app's window to the window alone.
@MainActor
final class WorkspaceDriver {
    /// Off screen, yet key and shown as far as AppKit and SwiftUI ask it while open: an occluded
    /// window's title bar items are never laid out. Closed, it says so, so later tests looking
    /// for an open window never find it.
    final class OffscreenWindow: NSWindow {
        var isOpen = true
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { isOpen }
        override var isKeyWindow: Bool { isOpen }
        override var occlusionState: NSWindow.OcclusionState { isOpen ? .visible : [] }
        override var isVisible: Bool { isOpen }
    }

    enum Button { case left, right }

    let model: WindowModel
    let window: NSWindow
    /// The windows the window asked the app to open.
    private(set) var requestedWindows: [WindowRequest] = []
    private let savedDefaults: [String: Any]

    private init(model: WindowModel, window: NSWindow, savedDefaults: [String: Any]) {
        self.model = model
        self.window = window
        self.savedDefaults = savedDefaults
    }

    /// A started mock window with its first pane up. With a request, a window a request opens
    /// (New Window, Open in New Window), which leaves the tabs as they are; without, the window
    /// starts from one new tab.
    static func start(
        width: CGFloat = 1200, height: CGFloat = 760, sidebar: Bool = true, request: WindowRequest? = nil
    ) async throws -> WorkspaceDriver {
        try XCTSkipUnless(LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        let savedDefaults = UserDefaults.standard.dictionaryRepresentation()
        let model = WindowModel(app: .shared)
        model.start()
        let frame = NSRect(x: -30000, y: -30000, width: width, height: height)
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let driver = WorkspaceDriver(model: model, window: window, savedDefaults: savedDefaults)
        let controller = NSHostingController(rootView: ThemedRoot {
            WindowContent(request: request, model: model).environment(AppModel.shared)
        })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        AppActivity.pretendActive(true)
        model.isSidebarShown = sidebar
        await driver.expect("the first pane comes up") { model.workspace?.focusedPane != nil && driver.terminal()?.window != nil }
        if request == nil { await driver.startFromOneTab() } else { await driver.settle() }
        // After the window's own start, which hands it the app's: New Window would open a real
        // window of the app.
        model.openWindow = { [weak driver] request in driver?.requestedWindows.append(request) }
        return driver
    }

    /// The mock host outlives a window: what earlier tests left on it goes, and one new tab
    /// with one pane is shown.
    private func startFromOneTab() async {
        let leftOver = model.groups.tabs
        model.newTab()
        await expect("a tab of its own") { model.groups.tabs.count == leftOver.count + 1 }
        model.closeTabs(leftOver, undoable: false)
        await expect("one tab, its terminal up") {
            model.groups.tabs.count == 1 && model.workspace?.session.activeTab?.root.panes.count == 1 && terminal()?.window != nil
        }
        await settle()
        // The window takes its very first click for itself, as a window brought forward does.
        if let terminal = terminal() { await click(terminal) }
        await settle()
    }

    func close() {
        model.isPaletteShown = false
        model.sheet = nil
        (window as? OffscreenWindow)?.isOpen = false
        window.close()
        model.close()
        AppActivity.pretendActive(false)
        restoreDefaults()
    }

    /// Puts back every setting this window changed, and only those.
    private func restoreDefaults() {
        let defaults = UserDefaults.standard
        let now = defaults.dictionaryRepresentation()
        for (key, value) in now where !(savedDefaults[key].map { ($0 as AnyObject).isEqual(value) } ?? false) {
            if let saved = savedDefaults[key] { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for (key, saved) in savedDefaults where now[key] == nil { defaults.set(saved, forKey: key) }
    }

    var workspace: Workspace {
        get throws { try XCTUnwrap(model.workspace, "the mock workspace") }
    }

    // MARK: Waiting

    func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The panes' layout motion has settled (until then terminals hide under their stills and
    /// take no clicks), and the window has drawn what it left.
    func settle() async {
        await pump(0.3)
        _ = await wait { !self.model.arrangement.isMoving }
        await pump(0.3)
    }

    func wait(timeout: Double = 10, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            await pump(0.03)
        }
        return true
    }

    func expect(_ message: @autoclosure () -> String, timeout: Double = 10, file: StaticString = #filePath, line: UInt = #line,
                until condition: () -> Bool) async {
        if await !wait(timeout: timeout, until: condition) { XCTFail("timed out: \(message())", file: file, line: line) }
    }

    // MARK: What is on screen

    var hostingView: NSView { window.contentView ?? NSView() }

    /// The focused pane's terminal view.
    func terminal() -> NSView? {
        guard let workspace = model.workspace, let id = workspace.focusedPane else { return nil }
        return workspace.pane(id)?.view
    }

    func terminal(of pane: PaneId) -> NSView? { model.workspace?.pane(pane)?.view }

    /// A view's frame in the window's coordinates.
    func frame(of view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

    /// The view a click at `point` (window coordinates) reaches.
    func hit(at point: CGPoint) -> NSView? {
        let frameView = hostingView.superview ?? hostingView
        return frameView.hitTest(frameView.convert(point, from: nil))
    }

    /// The sidebar's list, as AppKit lays it out.
    func sidebarTable() -> NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.numberOfRows > 0 { return table }
            for subview in view.subviews { if let table = find(subview) { return table } }
            return nil
        }
        return find(hostingView)
    }

    /// The sidebar row of `id` (`tab/<ref>`, `project/<id>`, `host/<id>` …), in window coordinates.
    func sidebarRowFrame(_ id: String) -> CGRect? {
        guard let table = sidebarTable() else { return nil }
        let ids = model.sidebarItems(drop: nil, projectMove: nil).items.map(\.id)
        // Inbox and Hosts come first, in rows of their own.
        let leading = table.numberOfRows - ids.count
        guard let index = ids.firstIndex(of: id).map({ $0 + leading }), leading >= 0, index < table.numberOfRows else { return nil }
        let rect = table.rect(ofRow: index)
        guard table.visibleRect.intersects(rect) else { return nil }
        return table.convert(rect, to: nil)
    }

    func sidebarRowFrame(of ref: TabRef) -> CGRect? { sidebarRowFrame("tab/\(ref)") }

    // MARK: Pointer

    /// A click as the window receives it. The release waits in the queue, where a control
    /// tracking the press reads it; otherwise it follows the press at once, so the clicks of a
    /// double click stay within the double-click interval however busy the machine is.
    func click(_ point: CGPoint, button: Button = .left, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) async {
        for clickCount in 1...count {
            guard let press = mouse(button.down, at: point, modifiers: modifiers, clickCount: clickCount),
                  let release = mouse(button.up, at: point, modifiers: modifiers, clickCount: clickCount)
            else { return XCTFail("could not make the click") }
            NSApp.postEvent(release, atStart: false)
            window.sendEvent(press)
            if let waiting = NSApp.nextEvent(matching: button.upMask, until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(waiting)
            }
        }
        await pump(0.15)
    }

    func click(_ view: NSView, button: Button = .left, count: Int = 1) async {
        let frame = frame(of: view)
        await click(CGPoint(x: frame.midX, y: frame.midY), button: button, count: count)
    }

    func click(_ frame: CGRect?, button: Button = .left, count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async {
        guard let frame else { return XCTFail("nothing there to click", file: file, line: line) }
        await click(CGPoint(x: frame.midX, y: frame.midY), button: button, count: count)
    }

    /// A press at `start`, moved to `end` in steps and let go, the window drawing between steps.
    func drag(from start: CGPoint, to end: CGPoint, steps: Int = 12, holdAtEnd: Double = 0) async {
        let moves = (1...steps).compactMap { step -> NSEvent? in
            let progress = CGFloat(step) / CGFloat(steps)
            return mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress))
        }
        guard let press = mouse(.leftMouseDown, at: start), let release = mouse(.leftMouseUp, at: end) else { return XCTFail("could not make the drag") }
        window.sendEvent(press)
        for move in moves {
            window.sendEvent(move)
            await pump(0.016)
        }
        if holdAtEnd > 0 { await pump(holdAtEnd) }
        window.sendEvent(release)
        await pump(0.1)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent? {
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)
    }

    // MARK: Menus

    /// Right-clicks at `point` and chooses the item at `path` (a submenu's title, then its
    /// item's) from the context menu that opens; the menu's titles, or nil when none opened.
    /// The press goes to the view under it, as the window would hand it on: a right click in a
    /// window that is not really key opens nothing otherwise.
    @discardableResult
    func contextMenu(at point: CGPoint, choose path: [String] = []) async -> [String]? {
        await openContextMenu(at: point, choose: path)
    }

    private func openContextMenu(at point: CGPoint, choose path: [String]) async -> [String]? {
        let opened = MenuWatch()
        defer { opened.stop() }
        guard let press = mouse(.rightMouseDown, at: point), let view = hit(at: point) else { return nil }
        view.rightMouseDown(with: press)
        await pump(0.1)
        guard let menu = opened.menu else { return nil }
        let titles = menu.items.map(\.title)
        if !path.isEmpty {
            var current = menu
            for title in path.dropLast() {
                guard let submenu = current.items.first(where: { $0.title == title })?.submenu else {
                    XCTFail("no submenu \(title) in \(current.items.map(\.title))")
                    return titles
                }
                submenu.update()
                current = submenu
            }
            guard let index = current.items.firstIndex(where: { $0.title == path.last }) else {
                XCTFail("no item \(path.last ?? "") in \(current.items.map(\.title))")
                return titles
            }
            current.performActionForItem(at: index)
        }
        await pump(0.2)
        return titles
    }

    func contextMenu(on frame: CGRect?, choose path: [String] = [], file: StaticString = #filePath, line: UInt = #line) async -> [String]? {
        guard let frame else {
            XCTFail("nothing there to right-click", file: file, line: line)
            return nil
        }
        return await contextMenu(at: CGPoint(x: frame.midX, y: frame.midY), choose: path)
    }

    /// The first menu that begins tracking, closed again at once from within its own loop.
    private final class MenuWatch: @unchecked Sendable {
        var menu: NSMenu?
        private var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
            ) { [weak self] notification in
                nonisolated(unsafe) let menu = notification.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let self, let menu, menu.supermenu == nil, self.menu == nil else { return }
                    self.menu = menu
                    RunLoop.main.perform(inModes: [.eventTracking, .default]) { menu.cancelTrackingWithoutAnimation() }
                }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    // MARK: Sheets

    /// The alert or sheet over the window.
    var sheet: NSWindow? { window.attachedSheet }

    /// Keys typed into the sheet's focused field over what it holds, then Return.
    func answerSheet(typing text: String) async {
        guard let sheet else { return XCTFail("no sheet is open") }
        await pump(0.2)
        (sheet.firstResponder as? NSTextView)?.selectAll(nil)
        if text.isEmpty { press("\u{7f}", keyCode: 51) }
        type(text)
        await pump(0.2)
        pressReturn()
        await pump(0.4)
    }

    // MARK: Keys

    /// A key press as the app receives it. A ⌘ key goes through the app (its shortcut handling,
    /// then the menu bar); others go to the window that has the keyboard, the sheet over the
    /// window while there is one (the app hands keys only to the key window it really has).
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        let target = sheet ?? window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            else { return XCTFail("could not make the key event") }
            if modifiers.contains(.command) {
                AppActivity.withKeyWindow(window) { NSApp.sendEvent(event) }
            } else if type == .keyUp || !target.performKeyEquivalent(with: event) {
                target.sendEvent(event)
            }
        }
    }

    func type(_ text: String) {
        for character in text {
            press(String(character), keyCode: Self.keyCodes[character] ?? 0)
        }
    }

    func pressReturn() { press("\r", keyCode: 36) }
    func pressEscape() { press("\u{1b}", keyCode: 53) }

    static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46, " ": 49,
    ]

    /// ⌘ plus `key` (and any other modifiers), as the keyboard sends it.
    func command(_ key: Character, _ extra: NSEvent.ModifierFlags = []) {
        press(String(key), keyCode: Self.keyCodes[key] ?? 0, modifiers: extra.union(.command))
    }
}

/// While a test pretends it, the app says it is active, as when a person works in it: AppKit
/// gives the first click in an inactive app's window to the window alone. While a ⌘ key is
/// handed to the app, its key window is the test's (the shortcuts act on the key window); only
/// then, as SwiftUI takes no clicks in a window the app names key without its knowing.
@MainActor
enum AppActivity {
    private(set) static weak var keyWindow: NSWindow?
    private static var windowsPretending = 0

    static func pretendActive(_ active: Bool) {
        let before = windowsPretending > 0
        windowsPretending = max(0, windowsPretending + (active ? 1 : -1))
        if before != (windowsPretending > 0) {
            exchange(#selector(getter: NSApplication.isActive), #selector(getter: NSApplication.testIsActive))
        }
    }

    static func withKeyWindow(_ window: NSWindow, _ body: () -> Void) {
        nameKey(window)
        defer { nameKey(nil) }
        body()
    }

    private static func nameKey(_ window: NSWindow?) {
        guard (window != nil) != (keyWindow != nil) else { return }
        keyWindow = window
        exchange(#selector(getter: NSApplication.keyWindow), #selector(getter: NSApplication.testKeyWindow))
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(NSApplication.self, original),
              let replacementMethod = class_getInstanceMethod(NSApplication.self, replacement)
        else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

extension NSApplication {
    @objc fileprivate var testIsActive: Bool { true }

    @objc fileprivate var testKeyWindow: NSWindow? {
        MainActor.assumeIsolated { AppActivity.keyWindow.map { $0.attachedSheet ?? $0 } }
    }
}

private extension WorkspaceDriver.Button {
    var down: NSEvent.EventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        }
    }

    var upMask: NSEvent.EventTypeMask {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        }
    }

    var up: NSEvent.EventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        }
    }
}
#endif
