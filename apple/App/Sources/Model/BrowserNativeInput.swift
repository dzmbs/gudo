import Foundation
import WebKit
#if os(macOS)
import AppKit
#endif

/// Real input for a page on the Mac: AppKit mouse and key events handed to the page's
/// `WKWebView`, which WebKit treats as the user's own — `isTrusted` events, `:hover`, menus that
/// open on hover, and pointer drags. The pointer on screen does not move. HTML drag and drop
/// is left to the page script: its drag session follows the real pointer.
///
/// The agent's tools ask for it per page and fall back to the page script when it is nil (iOS,
/// which has no public way to do this; a page that is not on screen):
///
///     if let input = await BrowserNativeInput.for(page.page) {
///         await input.click(at: point)          // CSS pixels in the viewport
///     } else {
///         // the page script's synthetic events
///     }
///
/// Keys need the page to be first responder: `press` and `type` make it so for the call and
/// then give the focus back.
@MainActor
struct BrowserNativeInput {
    #if os(macOS)
    let view: WKWebView

    /// The input of the view showing `page`, if it is in a window.
    static func `for`(_ page: any BrowserPageContent) async -> BrowserNativeInput? {
        let token = UUID().uuidString
        do {
            _ = try await page.run("window.__unInputToken = token", arguments: ["token": token], in: world)
        } catch {
            return nil
        }
        for window in NSApp.windows {
            guard let content = window.contentView else { continue }
            for view in webViews(in: content) {
                let mark = try? await view.evaluateJavaScript("window.__unInputToken", in: nil, contentWorld: world) as? String
                if mark == token { return BrowserNativeInput(view: view) }
            }
        }
        return nil
    }

    private static let world = WKContentWorld.world(name: "unnamed-input")

    private static func webViews(in view: NSView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap(webViews)
    }

    // MARK: Pointer

    /// Hover needs the page's window to be key (WebKit ignores moves in other windows).
    func move(to point: CGPoint) async {
        send(.mouseMoved, at: point)
        await pause()
    }

    func click(at point: CGPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) async {
        await move(to: point)
        for n in 1...max(1, count) {
            send(.leftMouseDown, at: point, clicks: n, modifiers: modifiers)
            send(.leftMouseUp, at: point, clicks: n, modifiers: modifiers)
        }
        await pause()
    }

    /// Presses at `from`, moves to `to` in steps, releases: pointer drags (sliders, sortable
    /// lists, canvases). False, doing nothing, when `from` is an HTML drag source: that starts a
    /// system drag session, which follows the real pointer rather than these events.
    @discardableResult
    func drag(from: CGPoint, to: CGPoint, steps: Int = 12) async -> Bool {
        let source = try? await view.evaluateJavaScript(
            "(() => { const e = document.elementFromPoint(\(from.x), \(from.y)); return !!(e && e.closest('[draggable=true], a[href], img')); })()",
            in: nil, contentWorld: Self.world) as? Bool
        if source != false { return false }
        await move(to: from)
        send(.leftMouseDown, at: from)
        await pause()
        for i in 1...max(1, steps) {
            let t = Double(i) / Double(max(1, steps))
            send(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            await pause(8)
        }
        send(.leftMouseUp, at: to)
        await pause()
        return true
    }

    func scroll(at point: CGPoint, dx: Double, dy: Double) async {
        await move(to: point)
        guard let window = view.window,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)
        else { return }
        wheel.location = window.convertPoint(toScreen: windowPoint(point))
        if let event = NSEvent(cgEvent: wheel) { view.scrollWheel(with: event) }
        await pause()
    }

    // MARK: The page script's list

    /// Runs what the page script listed instead of dispatching (`native` in `act`): moves,
    /// clicks, keys, text, wheels and drags, in order.
    func perform(_ ops: [[String: Any]]) async {
        func number(_ op: [String: Any], _ key: String) -> Double { (op[key] as? NSNumber)?.doubleValue ?? 0 }
        for op in ops {
            let point = CGPoint(x: number(op, "x"), y: number(op, "y"))
            switch op["op"] as? String {
            case "move": await move(to: point)
            case "click":
                let names = op["modifiers"] as? [String] ?? []
                var flags: NSEvent.ModifierFlags = []
                if names.contains("shiftKey") { flags.insert(.shift) }
                if names.contains("ctrlKey") { flags.insert(.control) }
                if names.contains("altKey") { flags.insert(.option) }
                if names.contains("metaKey") { flags.insert(.command) }
                await click(at: point, count: Int(number(op, "count")), modifiers: flags)
            case "key": await press(op["chord"] as? String ?? "")
            case "text": await type(op["text"] as? String ?? "")
            case "wheel": await scroll(at: point, dx: number(op, "dx"), dy: number(op, "dy"))
            case "drag": await drag(from: point, to: CGPoint(x: number(op, "toX"), y: number(op, "toY")))
            default: break
            }
        }
    }

    // MARK: Keys

    /// A chord as the agent writes it: `Enter`, `cmd+a`, `shift+Tab`, `x`.
    func press(_ chord: String) async {
        let parts = chord.split(separator: "+").map { $0.lowercased() }
        guard let last = parts.last else { return }
        var flags: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "meta": flags.insert(.command)
            case "ctrl", "control": flags.insert(.control)
            case "alt", "option", "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        let original = String(chord.split(separator: "+").last ?? "")
        if let (code, characters) = Self.named[last] {
            await press(keyCode: code, characters: characters, modifiers: flags)
        } else if original.count == 1, let code = Self.codes[Character(last)] {
            await press(keyCode: code, characters: flags.contains(.shift) ? original.uppercased() : original, modifiers: flags)
        } else if flags.isEmpty {
            await type(original)
        }
    }

    /// Virtual key codes (ANSI layout) and the characters AppKit gives them.
    private static let named: [String: (UInt16, String)] = [
        "enter": (0x24, "\r"), "return": (0x24, "\r"), "tab": (0x30, "\t"), "space": (0x31, " "), " ": (0x31, " "),
        "backspace": (0x33, "\u{7F}"), "delete": (0x75, "\u{F728}"), "escape": (0x35, "\u{1B}"), "esc": (0x35, "\u{1B}"),
        "left": (0x7B, "\u{F702}"), "arrowleft": (0x7B, "\u{F702}"), "right": (0x7C, "\u{F703}"), "arrowright": (0x7C, "\u{F703}"),
        "down": (0x7D, "\u{F701}"), "arrowdown": (0x7D, "\u{F701}"), "up": (0x7E, "\u{F700}"), "arrowup": (0x7E, "\u{F700}"),
        "home": (0x73, "\u{F729}"), "end": (0x77, "\u{F72B}"), "pageup": (0x74, "\u{F72C}"), "pagedown": (0x79, "\u{F72D}"),
    ]

    private static let codes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
    ]

    /// A key by its code (`kVK_Return` = 36), with modifiers.
    func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) async {
        await focused {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
                else { continue }
                if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
            }
        }
    }

    /// Text as the input method commits it (any script, no key codes).
    func type(_ text: String) async {
        await focused { view.insertText(text) }
    }

    private func focused(_ body: () -> Void) async {
        guard let window = view.window else { return }
        let previous = window.firstResponder
        if previous !== view { window.makeFirstResponder(view) }
        body()
        await pause()
        if previous !== view, let previous { window.makeFirstResponder(previous) }
    }

    // MARK: Plumbing

    private func send(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(
                  with: type, location: windowPoint(point), modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                  clickCount: type == .mouseMoved || type == .leftMouseDragged ? 0 : clicks,
                  pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)
        else { return }
        switch type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: window.sendEvent(event)
        }
    }

    /// A viewport point (CSS pixels) in the window's coordinates.
    private func windowPoint(_ point: CGPoint) -> NSPoint {
        let zoom = view.pageZoom * view.magnification
        let local = NSPoint(x: point.x * zoom, y: view.isFlipped ? point.y * zoom : view.bounds.height - point.y * zoom)
        return view.convert(local, to: nil)
    }

    private func pause(_ ms: Int = 30) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }
    #else
    static func `for`(_ page: any BrowserPageContent) async -> BrowserNativeInput? { nil }
    #endif
}
