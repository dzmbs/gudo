#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import XCTest
@testable import App

/// The Settings window off screen, used the way a person uses it: clicks on its controls and
/// keys through the app, each control found among the form's views top to bottom. Every setting the window writes is put back when it closes (the test host shares its
/// defaults with the development app).
@MainActor
final class SettingsDriver {
    /// The window Settings opens at: the view's ideal size.
    static let defaultSize = CGSize(width: 760, height: 720)

    let window: NSWindow
    let navigation: SettingsNavigation
    private let savedDefaults: SavedDefaults

    private init(window: NSWindow, navigation: SettingsNavigation, savedDefaults: SavedDefaults) {
        self.window = window
        self.navigation = navigation
        self.savedDefaults = savedDefaults
    }

    static func open(
        _ navigation: SettingsNavigation = SettingsNavigation(), size: CGSize = defaultSize,
        accessibility: ChromeAccessibility? = nil
    ) async throws -> SettingsDriver {
        try XCTSkipUnless(LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        let savedDefaults = SavedDefaults()
        let frame = NSRect(x: -30000, y: -30000, width: size.width, height: size.height)
        let window = WorkspaceDriver.OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        let controller = NSHostingController(rootView: SettingsView(navigation: navigation)
            .environment(\.forcedChromeAccessibility, accessibility))
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        AppActivity.pretendActive(true)
        let driver = SettingsDriver(window: window, navigation: navigation, savedDefaults: savedDefaults)
        await driver.pump(1.2)
        return driver
    }

    func close() {
        window.close()
        AppActivity.pretendActive(false)
        savedDefaults.restore()
    }

    // MARK: Waiting

    func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func wait(timeout: Double = 5, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            await pump(0.03)
        }
        return true
    }

    func expect(_ message: @autoclosure () -> String, timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line,
                until condition: () -> Bool) async {
        if await !wait(timeout: timeout, until: condition) { XCTFail("timed out: \(message())", file: file, line: line) }
    }

    // MARK: What is on screen

    var hostingView: NSView { window.contentView ?? NSView() }

    /// The pane's form: the widest scroll view right of the sidebar.
    var form: NSScrollView? {
        Self.descendants(of: hostingView.superview ?? hostingView)
            .compactMap { $0 as? NSScrollView }
            .filter { $0.convert($0.bounds, to: nil).minX > 200 }
            .max { $0.frame.width < $1.frame.width }
    }

    /// The sidebar's panes, or the search results in their place.
    var sidebar: NSScrollView? {
        Self.descendants(of: hostingView.superview ?? hostingView)
            .compactMap { $0 as? NSScrollView }
            .first { $0.convert($0.bounds, to: nil).maxX <= 221 }
    }

    /// The form's controls of a kind, top to bottom.
    func controls(_ kind: ControlKind) -> [NSView] {
        // SwiftUI's own focusable things stand in as views beside the form's document, made
        // when the window's key view loop is worked out.
        if kind == .focusable { window.recalculateKeyViewLoop() }
        guard let form, let root = kind == .focusable ? form.contentView : form.documentView else { return [] }
        return Self.descendants(of: root)
            .filter { kind.matches($0) }
            .sorted { frame(of: $0).maxY > frame(of: $1).maxY }
    }

    /// The things Tab or a click can focus in the sidebar (its panes, or the search results).
    var sidebarItems: [NSView] {
        window.recalculateKeyViewLoop()
        guard let sidebar else { return [] }
        return Self.descendants(of: sidebar)
            .filter { ControlKind.focusable.matches($0) }
            .sorted { frame(of: $0).maxY > frame(of: $1).maxY }
    }

    var searchField: NSTextField? {
        Self.descendants(of: hostingView.superview ?? hostingView).lazy.compactMap { $0 as? NSTextField }.first { $0.isEditable }
    }

    /// A pushed page's search, in the window's toolbar.
    var toolbarSearchField: NSSearchField? {
        Self.descendants(of: hostingView.superview ?? hostingView).lazy.compactMap { $0 as? NSSearchField }.first
    }

    var isSearchFocused: Bool {
        guard let editor = window.firstResponder as? NSTextView, let field = searchField else { return false }
        return editor.delegate as? NSTextField === field
    }

    /// A view's frame in the window's coordinates.
    func frame(of view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Scrolls the form until `view` is in sight below the title bar.
    func reveal(_ view: NSView) async {
        guard let form else { return }
        let inset = form.contentInsets.top
        view.scrollToVisible(view.bounds.insetBy(dx: 0, dy: -inset))
        form.reflectScrolledClipView(form.contentView)
        await pump(0.3)
    }

    // MARK: Pointer

    func click(_ point: CGPoint, count: Int = 1) async {
        for clickCount in 1...count {
            guard let press = mouse(.leftMouseDown, at: point, clickCount: clickCount),
                  let release = mouse(.leftMouseUp, at: point, clickCount: clickCount)
            else { return XCTFail("could not make the click") }
            NSApp.postEvent(release, atStart: false)
            deliver(press, matching: .leftMouseDown)
            if let waiting = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(waiting)
            }
        }
        await pump(0.3)
    }

    /// Hands `event` to the window as the app's current event, as the event loop does: SwiftUI
    /// tells a person's click or key from AppKit's own changes by it.
    private func deliver(_ event: NSEvent, matching mask: NSEvent.EventTypeMask) {
        NSApp.postEvent(event, atStart: true)
        guard let current = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) else {
            return XCTFail("the event never reached the queue")
        }
        window.sendEvent(current)
    }

    /// Brings `view` into sight and clicks its middle.
    func click(_ view: NSView?, file: StaticString = #filePath, line: UInt = #line) async {
        guard let view else { return XCTFail("nothing there to click", file: file, line: line) }
        if let form, view.isDescendant(of: form) { await reveal(view) }
        let viewFrame = frame(of: view)
        await click(CGPoint(x: viewFrame.midX, y: viewFrame.midY))
    }

    /// Clicks a pop-up button and chooses `title` from the menu it opens; the menu's titles.
    @discardableResult
    func choose(_ title: String, in popUp: NSView?, file: StaticString = #filePath, line: UInt = #line) async -> [String] {
        await choose(in: popUp, file: file, line: line) { $0.title == title }
    }

    /// Clicks a pop-up button and chooses the first item `pick` accepts; the menu's titles.
    @discardableResult
    func choose(in popUp: NSView?, file: StaticString = #filePath, line: UInt = #line, _ pick: (NSMenuItem) -> Bool) async -> [String] {
        guard let menu = await openMenu(of: popUp, file: file, line: line) else { return [] }
        let titles = menu.items.map(\.title)
        guard let index = menu.items.firstIndex(where: pick) else {
            XCTFail("nothing to choose in \(titles)", file: file, line: line)
            return titles
        }
        menu.performActionForItem(at: index)
        await pump(0.3)
        return titles
    }

    /// The item a pop-up shows as chosen (its menu's checked item), read from the menu a click
    /// opens.
    func chosenTitle(of popUp: NSView?, file: StaticString = #filePath, line: UInt = #line) async -> String? {
        await openMenu(of: popUp, file: file, line: line)?.items.first { $0.state == .on }?.title
    }

    private func openMenu(of popUp: NSView?, file: StaticString, line: UInt) async -> NSMenu? {
        guard let popUp else {
            XCTFail("no pop-up there", file: file, line: line)
            return nil
        }
        let watch = MenuWatch()
        defer { watch.stop() }
        await click(popUp)
        guard let menu = watch.menu else {
            XCTFail("the pop-up opened no menu", file: file, line: line)
            return nil
        }
        return menu
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1)
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

    // MARK: Keys

    /// A key press as the window receives it; ⌘ keys go through the app (its menus) first.
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            else { return XCTFail("could not make the key event") }
            if modifiers.contains(.command) {
                AppActivity.withKeyWindow(window) {
                    NSApp.postEvent(event, atStart: true)
                    if let current = NSApp.nextEvent(matching: type == .keyDown ? .keyDown : .keyUp, until: .distantPast, inMode: .default, dequeue: true) {
                        NSApp.sendEvent(current)
                    }
                }
            } else {
                deliver(event, matching: type == .keyDown ? .keyDown : .keyUp)
            }
        }
        await pump(0.15)
    }

    func type(_ text: String) async {
        for character in text {
            await press(String(character), keyCode: WorkspaceDriver.keyCodes[character] ?? 0)
        }
    }

    func pressTab(backward: Bool = false) async { await press("\t", keyCode: 48, modifiers: backward ? .shift : []) }
    func pressReturn() async { await press("\r", keyCode: 36) }
    func pressEscape() async { await press("\u{1b}", keyCode: 53) }
    func pressSpace() async { await press(" ", keyCode: 49) }
    func pressDown() async { await press(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), keyCode: 125, modifiers: [.numericPad, .function]) }
    func pressUp() async { await press(String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), keyCode: 126, modifiers: [.numericPad, .function]) }
}

/// The views a Settings form is made of.
enum ControlKind {
    case toggle, popUp, stepper, slider
    /// What Tab or a click can focus that SwiftUI draws itself: buttons, links, rows.
    case focusable

    func matches(_ view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        return switch self {
        case .toggle: name == "PlatformSwitch" || (view as? NSButton).map { $0.bezelStyle == .regularSquare && name.contains("Checkbox") } == true
        case .popUp: view is NSPopUpButton
        case .stepper: view is NSStepper
        case .slider: view is NSSlider
        case .focusable: name == "KeyViewProxy"
        }
    }
}

/// Every user default as it stood, to put back what a test changed, and only that.
@MainActor
struct SavedDefaults {
    private let saved = UserDefaults.standard.dictionaryRepresentation()

    func restore() {
        let defaults = UserDefaults.standard
        let now = defaults.dictionaryRepresentation()
        for (key, value) in now where !(saved[key].map { ($0 as AnyObject).isEqual(value) } ?? false) {
            if let previous = saved[key] { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for (key, previous) in saved where now[key] == nil { defaults.set(previous, forKey: key) }
    }
}
#endif
