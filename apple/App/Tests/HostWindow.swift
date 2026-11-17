#if os(macOS)
import AppKit
import ApplicationServices
import DesignSystem
import HostKit
import SwiftUI
import TerminalCore
import TerminalRenderer
import XCTest
@testable import App

/// A real window of the app off screen, on a real host: the terminal typed into key by key,
/// and SwiftUI controls (in the window or a sheet) found by accessibility identifier or label
/// and clicked where they are drawn.
@MainActor
final class HostWindow {
    final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    let model: WindowModel
    let window: NSWindow

    /// A window of the app's own content, its sidebar hidden.
    init(width: CGFloat = 1000, height: CGFloat = 700) {
        model = WindowModel(app: .shared)
        model.start()
        window = Self.window(width: width, height: height) { [model] in
            WindowContent(request: nil, model: model).environment(AppModel.shared)
        }
        model.isSidebarShown = false
        // On screen behind another app's window: an offscreen test window's scene is in the background.
        model.isOnScreen = true
    }

    /// A window showing `content`, with the app's environment around it.
    init(width: CGFloat = 700, height: CGFloat = 600, @ViewBuilder content: @escaping () -> some View) {
        model = WindowModel(app: .shared)
        window = Self.window(width: width, height: height) { [model] in
            content().environment(model).environment(AppModel.shared)
        }
    }

    private static func window(width: CGFloat, height: CGFloat, content: @escaping () -> some View) -> NSWindow {
        let frame = NSRect(x: -30000, y: -30000, width: width, height: height)
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: ThemedRoot { content() })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }

    func close() {
        model.sheet = nil
        for sheet in window.sheets { window.endSheet(sheet) }
        window.close()
        model.close()
    }

    // MARK: Waiting

    struct TimedOut: Error, CustomStringConvertible {
        let what: String
        let screen: String
        var description: String { "timed out: \(what)\n\(screen)" }
    }

    func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: what, screen: screenText) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Terminal

    var pane: Pane? {
        guard let workspace = model.workspace, let id = workspace.focusedPane else { return nil }
        return workspace.pane(id)
    }

    var screenText: String { pane?.view.surface.terminal.visibleText() ?? "" }

    var rows: [String] {
        screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var lastLine: String { rows.last { !$0.isEmpty } ?? "" }

    /// Waits for the focused pane to be live at a prompt, and gives it the keyboard.
    func waitForShell(timeout: Duration = .seconds(20)) async throws {
        try await until("a live shell", timeout: timeout) {
            guard let pane = self.pane else { return false }
            return pane.connection == .live && pane.view.window != nil && self.lastLine.hasSuffix("%")
        }
        window.makeFirstResponder(pane?.view)
    }

    /// Types `command` and Return, and waits for the row `showing` and a prompt after it.
    func run(_ command: String, showing: String) async throws {
        type(command + "\r")
        try await until("\(command) prints \(showing)") {
            let rows = self.rows
            guard let row = rows.lastIndex(of: showing) else { return false }
            return rows[(row + 1)...].contains { $0.hasSuffix("%") }
        }
    }

    /// Each character pressed and released on the window, as a US keyboard sends it.
    func type(_ text: String) {
        for character in text {
            let layout = PhysicalKey.usLayout(character)
            let keyCode = character == "\r" ? 36 : layout.flatMap { Self.macKeyCodes[$0.unshifted] } ?? 0
            press(String(character), keyCode: UInt16(keyCode), modifiers: layout?.shift == true ? .shift : [])
        }
    }

    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) {
        let target = target ?? window
        for eventType in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: eventType, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)
            if let event { target.sendEvent(event) }
        }
    }

    private static let macKeyCodes: [Character: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
    ]

    // MARK: Controls

    /// The sheet over the window, if one is up.
    var sheet: NSWindow? { window.attachedSheet }

    /// An accessibility element of the window: an AppKit view, or one of SwiftUI's own nodes,
    /// which answer the same messages without declaring the protocol.
    struct Element {
        let object: AnyObject

        var identifier: String? { object.accessibilityIdentifier?() }
        var label: String? { object.accessibilityLabel?() ?? nil }
        var title: String? { object.accessibilityTitle?() ?? nil }
        var value: String? {
            let value: Any?? = object.accessibilityValue?()
            return (value ?? nil) as? String
        }
        var role: String? { (object.accessibilityRole?() ?? nil)?.rawValue }
        var frame: NSRect { object.accessibilityFrame?() ?? .zero }
        var isEnabled: Bool { object.isAccessibilityEnabled?() ?? true }
        var children: [Any] { (object.accessibilityChildren?() ?? nil) ?? [] }
        var words: String { [label, value, title].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// Every accessibility element under `root` (the window's content, or a sheet's). SwiftUI
    /// builds its nodes only once an assistive client has asked this process for something.
    static func elements(under root: AnyObject) -> [Element] {
        enableAccessibility()
        var found: [Element] = []
        var queue: [Any] = [root]
        var seen = Set<ObjectIdentifier>()
        while let next = queue.popLast() {
            let object = next as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let element = Element(object: object)
            found.append(element)
            queue.append(contentsOf: element.children)
            if let view = object as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return found
    }

    private static var accessibilityEnabled = false

    private static func enableAccessibility() {
        guard !accessibilityEnabled else { return }
        accessibilityEnabled = true
        var windows: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows)
    }

    /// The element with accessibility identifier `identifier` (or, failing that, label or
    /// title `identifier`) in the sheet when one is up, else the window.
    func element(_ identifier: String, inSheet: Bool? = nil) -> Element? {
        let root: NSWindow = (inSheet ?? (sheet != nil)) ? (sheet ?? window) : window
        guard let content = root.contentView else { return nil }
        let all = Self.elements(under: content)
        return all.first { $0.identifier == identifier }
            ?? all.first { $0.label == identifier || $0.title == identifier }
    }

    func waitForElement(_ identifier: String, inSheet: Bool? = nil, timeout: Duration = .seconds(5)) async throws -> Element {
        var found: Element?
        do {
            try await until("\(identifier) is shown", timeout: timeout) {
                found = self.element(identifier, inSheet: inSheet)
                return found != nil
            }
        } catch {
            throw TimedOut(what: "\(identifier) is shown", screen: describeElements())
        }
        return try XCTUnwrap(found)
    }

    /// Clicks the middle of the control `identifier` names, in whichever window shows it.
    func click(_ identifier: String, inSheet: Bool? = nil, button: WindowDriver.MouseButton = .left) async throws {
        let element = try await waitForElement(identifier, inSheet: inSheet)
        try await click(element, button: button)
    }

    func click(_ element: Element, button: WindowDriver.MouseButton = .left) async throws {
        let target = (inSheet(element) ? sheet : nil) ?? window
        let frame = element.frame
        XCTAssertFalse(frame.isEmpty, "\(element) has a frame")
        let point = target.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        try await click(at: point, in: target, button: button)
    }

    private func inSheet(_ element: Element) -> Bool {
        guard let sheet, let content = sheet.contentView else { return false }
        return Self.elements(under: content).contains { $0.object === element.object }
    }

    /// A press and its release at `point`, through the window as AppKit delivers them.
    func click(at point: NSPoint, in target: NSWindow, button: WindowDriver.MouseButton = .left) async throws {
        let types: (NSEvent.EventType, NSEvent.EventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        case .middle: (.otherMouseDown, .otherMouseUp)
        }
        nonisolated(unsafe) let press = try WindowDriver.mouseEvent(types.0, at: point, in: target, clickCount: 1)
        nonisolated(unsafe) let release = try WindowDriver.mouseEvent(types.1, at: point, in: target, clickCount: 1)
        nonisolated(unsafe) let receiver = target
        let releaseLater = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                if RunLoop.current.currentMode == .eventTracking || button != .left {
                    NSApp.postEvent(release, atStart: false)
                } else {
                    receiver.sendEvent(release)
                }
            }
        }
        RunLoop.main.add(releaseLater, forMode: .common)
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                if button == .left { receiver.sendEvent(press) } else { NSApp.postEvent(press, atStart: false) }
            }
        }
        await pump(0.6)
    }

    /// Clicks the text field `identifier` names and types `text` into it, as the keyboard's
    /// input reaches a field.
    func enter(_ text: String, into identifier: String, replacing: Bool = true) async throws {
        try await click(identifier)
        let target = sheet ?? window
        let editor = try XCTUnwrap(target.firstResponder as? NSTextView, "\(identifier) takes the keyboard: \(String(describing: target.firstResponder))")
        if replacing { editor.selectAll(nil) }
        editor.insertText(text, replacementRange: editor.selectedRange())
        await pump(0.3)
    }

    /// The text of every static text and field under the sheet or the window, for asserting
    /// what it says.
    func texts(inSheet: Bool? = nil) -> [String] {
        let root: NSWindow = (inSheet ?? (sheet != nil)) ? (sheet ?? window) : window
        guard let content = root.contentView else { return [] }
        return Self.elements(under: content).map(\.words).filter { !$0.isEmpty }
    }

    func says(_ text: String, inSheet: Bool? = nil) -> Bool {
        texts(inSheet: inSheet).contains { $0.contains(text) }
    }

    func describeElements() -> String {
        let root = sheet ?? window
        guard let content = root.contentView else { return "no content" }
        return Self.elements(under: content).map { element in
            "\(Swift.type(of: element.object)) id=\(element.identifier ?? "-") role=\(element.role ?? "-") words=\(element.words) frame=\(element.frame)"
        }.joined(separator: "\n")
    }

    /// Shown and takes clicks.
    func isEnabled(_ identifier: String) -> Bool {
        element(identifier)?.isEnabled == true
    }

    /// Shown, dimmed.
    func isDisabled(_ identifier: String) -> Bool {
        element(identifier)?.isEnabled == false
    }
}

/// Presents `content` as a sheet of the window it sits in, as the app presents its sheets, and
/// tells whether it is still up (a sheet's Cancel, Done and success dismiss it).
@MainActor
@Observable
final class SheetPresenter {
    var isPresented = true
}

struct PresentedSheet<Content: View>: View {
    @Bindable var presenter: SheetPresenter
    @ViewBuilder let content: () -> Content

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $presenter.isPresented) {
                ThemedRoot { content() }.chromeSheetBackground()
            }
    }
}
#endif
