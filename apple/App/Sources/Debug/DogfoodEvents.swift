#if DEBUG && os(macOS)
import AppKit

/// Synthesized input for the dogfood runner. Events are real `NSEvent`s posted to the app's own
/// event queue (`NSApp.postEvent`), so they take the same path as hardware input: `NSApp.sendEvent`
/// → key equivalents / menu bar → key window → first responder (`TerminalView.keyDown`,
/// `interpretKeyEvents`, …). In-process events need no Accessibility or Input Monitoring permission.
enum DogfoodEvents {
    struct Key {
        var code: UInt16
        var characters: String
        var charactersIgnoringModifiers: String
        var flags: NSEvent.ModifierFlags
    }

    enum ParseError: Error, CustomStringConvertible {
        case unknownKey(String)
        var description: String {
            switch self {
            case .unknownKey(let key): "unknown key \"\(key)\""
            }
        }
    }

    // US ANSI virtual key codes.
    private static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50, " ": 49,
    ]
    private static let shifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".",
        "?": "/",
    ]
    /// Named keys: code and the AppKit characters they produce.
    private static let named: [String: (UInt16, String)] = [
        "return": (36, "\r"), "enter": (36, "\r"), "tab": (48, "\t"), "space": (49, " "),
        "backspace": (51, "\u{7f}"), "delete": (51, "\u{7f}"), "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"), "pageup": (116, "\u{F72C}"), "pagedown": (121, "\u{F72D}"),
        "forwarddelete": (117, "\u{F728}"),
        "f1": (122, "\u{F704}"), "f2": (120, "\u{F705}"), "f3": (99, "\u{F706}"), "f4": (118, "\u{F707}"),
        "f5": (96, "\u{F708}"), "f6": (97, "\u{F709}"), "f7": (98, "\u{F70A}"), "f8": (100, "\u{F70B}"),
        "f9": (101, "\u{F70C}"), "f10": (109, "\u{F70D}"), "f11": (103, "\u{F70E}"), "f12": (111, "\u{F70F}"),
    ]

    /// Parses "ctrl+c", "cmd+shift+d", "cmd+opt+left", "return", "q".
    static func parse(_ spec: String) throws -> Key {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" / "+" means the plus key.
        if spec.hasSuffix("++") || spec == "+" { parts = parts.filter { !$0.isEmpty } + ["+"] }
        let name = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts {
            switch modifier.lowercased() {
            case "cmd", "command", "super": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "ctrl", "control": flags.insert(.control)
            case "opt", "option", "alt": flags.insert(.option)
            default: throw ParseError.unknownKey(spec)
            }
        }
        if let (code, characters) = named[name.lowercased()] {
            if characters.unicodeScalars.first!.value >= 0xF700 { flags.formUnion([.function]) }
            if (123...126).contains(code) { flags.insert(.numericPad) }
            return Key(code: code, characters: characters, charactersIgnoringModifiers: characters, flags: flags)
        }
        guard name.count == 1, var char = name.first else { throw ParseError.unknownKey(spec) }
        if let base = shifted[char] {
            flags.insert(.shift)
            char = base
        } else if char.isUppercase, char.isASCII {
            flags.insert(.shift)
            char = Character(char.lowercased())
        }
        guard let code = letterCodes[char] else { throw ParseError.unknownKey(spec) }
        return key(code: code, base: char, flags: flags)
    }

    /// The key that types `char` on a US layout; non-ASCII text is delivered as the key event's
    /// characters (what an input method commits).
    static func typing(_ char: Character) -> Key {
        switch char {
        case "\n", "\r": return Key(code: 36, characters: "\r", charactersIgnoringModifiers: "\r", flags: [])
        case "\t": return Key(code: 48, characters: "\t", charactersIgnoringModifiers: "\t", flags: [])
        default: break
        }
        if let base = shifted[char], let code = letterCodes[base] {
            return Key(code: code, characters: String(char), charactersIgnoringModifiers: String(char), flags: .shift)
        }
        if char.isASCII, char.isUppercase, let code = letterCodes[Character(char.lowercased())] {
            return Key(code: code, characters: String(char), charactersIgnoringModifiers: String(char), flags: .shift)
        }
        if let code = letterCodes[char] {
            return Key(code: code, characters: String(char), charactersIgnoringModifiers: String(char), flags: [])
        }
        // No key on the layout: keyCode 0 with the text, as a committed IME string arrives.
        return Key(code: 0, characters: String(char), charactersIgnoringModifiers: String(char), flags: [])
    }

    /// The virtual key code for a key equivalent's character (letters, digits, punctuation, named keys).
    static func keyCode(for character: Character) -> UInt16? {
        let lower = Character(character.lowercased())
        if let code = letterCodes[lower] { return code }
        if let base = shifted[character] { return letterCodes[base] }
        return named.values.first { $0.1 == String(character) }?.0
    }

    private static func key(code: UInt16, base: Character, flags: NSEvent.ModifierFlags) -> Key {
        let ignoring = flags.contains(.shift) ? Self.shiftedString(base) : String(base)
        var characters = ignoring
        if flags.contains(.control), !flags.contains(.command), let ascii = base.asciiValue {
            // Control-letter produces the C0 control (^C = 0x03), like the hardware path.
            let upper = Character(base.uppercased()).asciiValue ?? ascii
            if (0x40...0x5F).contains(upper) { characters = String(UnicodeScalar(upper & 0x1F)) }
        }
        return Key(code: code, characters: characters, charactersIgnoringModifiers: ignoring, flags: flags)
    }

    private static func shiftedString(_ base: Character) -> String {
        if let shiftedCharacter = shifted.first(where: { $0.value == base })?.key { return String(shiftedCharacter) }
        return base.uppercased()
    }

    static func keyEvents(_ key: Key, window: NSWindow) -> [NSEvent] {
        [NSEventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false, keyCode: key.code)
        }
    }

    typealias NSEventType = NSEvent.EventType

    static func mouse(
        _ type: NSEvent.EventType, at windowPoint: CGPoint, window: NSWindow, flags: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// A line-based scroll-wheel event at a window point (positive `lines` scrolls content up,
    /// i.e. towards older lines, as a wheel rolled away from the user does).
    static func scroll(lines: Int32, at windowPoint: CGPoint, window: NSWindow) -> NSEvent? {
        guard let wheelEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)
        else { return nil }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        // CG global coordinates have a top-left origin on the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        wheelEvent.location = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        let number = Int64(window.windowNumber)
        wheelEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: number)
        wheelEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: number)
        return NSEvent(cgEvent: wheelEvent)
    }
}

/// Posts events to the app's queue and waits until AppKit has dispatched them: a marker
/// application-defined event is posted after them, and the queue is FIFO.
@MainActor
final class DogfoodEventPump {
    private var monitor: Any?
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextMarker = 1

    private var keyMonitor: Any?
    /// Key events delivered to the window directly because the app was not active.
    private(set) var redirectedKeyEvents = 0

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            guard event.subtype.rawValue == 0x0D06, let self else { return event }
            self.waiting.removeValue(forKey: event.data1)?.resume()
            return nil
        }
        // While the app is inactive (screen locked, another app frontmost) there is no key window:
        // `NSApp.sendEvent` drops key events and SwiftUI disables commands that read a focused
        // scene value. Deliver ours as AppKit would to the key window (see `deliverInactive`).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard NSApp.keyWindow == nil, let self,
                  let window = event.window ?? NSApp.window(withWindowNumber: event.windowNumber)
            else { return event }
            self.redirectedKeyEvents += 1
            self.deliverInactive(event, window: window)
            return nil
        }
    }

    private weak var mouseTarget: NSView?

    /// Mouse events go straight to `NSWindow.sendEvent` rather than through the queue: a posted
    /// mouse event's location is round-tripped through screen coordinates on dequeue, which is
    /// off by several points when the display is asleep or locked. While the app is inactive, a
    /// click would only activate it (no `acceptsFirstMouse`) and activation is impossible on a
    /// locked screen, so hit-test as `sendEvent` does and send drags and the release to the view
    /// that got the press.
    func sendMouse(_ events: [NSEvent], window: NSWindow) async {
        for event in events {
            // A CGEvent-made scroll event has no window and carries screen coordinates, which
            // `NSWindow.sendEvent` reads as window coordinates: the wheel then lands wherever
            // that point falls (often outside the pane). Hit-test it ourselves, always.
            if NSApp.keyWindow === window, event.type != .scrollWheel {
                window.sendEvent(event)
            } else {
                deliverMouseInactive(event, window: window)
            }
        }
        await drain(window: window)
    }

    private func deliverMouseInactive(_ event: NSEvent, window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        let target: NSView?
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .scrollWheel:
            // A CGEvent-made scroll event has no window: its location is in screen coordinates.
            let location = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
            target = root.hitTest(root.convert(location, from: nil))
            if event.type != .scrollWheel { mouseTarget = target }
        default:
            target = mouseTarget
        }
        guard let target else { return }
        switch event.type {
        case .leftMouseDown: target.mouseDown(with: event)
        case .leftMouseDragged: target.mouseDragged(with: event)
        case .leftMouseUp: target.mouseUp(with: event); mouseTarget = nil
        case .rightMouseDown: target.rightMouseDown(with: event)
        case .rightMouseUp: target.rightMouseUp(with: event); mouseTarget = nil
        default: target.scrollWheel(with: event)
        }
    }

    /// Runs a shortcut whose menu item SwiftUI disabled because no scene is focused (inactive
    /// app), through the same action the menu item calls. Returns whether it handled the event.
    var performDisabledShortcut: ((NSEvent) -> Bool)?
    /// How the last shortcut was delivered: "menu", "window", "responder", "action", "unhandled".
    private(set) var lastShortcutRoute = ""

    private func deliverInactive(_ event: NSEvent, window: NSWindow) {
        let flags = event.modifierFlags
        if event.type == .keyDown, !flags.isDisjoint(with: [.command, .control]) {
            // Key equivalents: the window's views (TerminalView takes ⌃ combos here), then the menu
            // bar, as `NSApp.sendEvent` does for the key window.
            if window.performKeyEquivalent(with: event) { lastShortcutRoute = "window"; return }
            if flags.contains(.command) {
                if Self.enabledMenuItem(NSApp.mainMenu, matching: event) != nil, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                    lastShortcutRoute = "menu"
                    return
                }
                // Edit menu items validate against the key window's responder chain; send their
                // actions to our first responder instead.
                let editActions: [String: Selector] = [
                    "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)), "a": #selector(NSText.selectAll(_:)),
                ]
                if flags.isDisjoint(with: [.shift, .option, .control]), let key = event.charactersIgnoringModifiers?.lowercased(),
                   let action = editActions[key], window.firstResponder?.tryToPerform(action, with: nil) == true
                {
                    lastShortcutRoute = "responder"
                    return
                }
                if performDisabledShortcut?(event) == true { lastShortcutRoute = "action"; return }
                lastShortcutRoute = "unhandled"
                return
            }
        }
        // `NSWindow.sendEvent` ignores keys while the window is not key; enter the responder chain
        // where it would.
        guard let responder = window.firstResponder else { return }
        if event.type == .keyDown { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
    }

    private static func enabledMenuItem(_ menu: NSMenu?, matching event: NSEvent) -> NSMenuItem? {
        guard let menu else { return nil }
        menu.update()
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        for item in menu.items {
            if let found = enabledMenuItem(item.submenu, matching: event) { return found }
            guard item.isEnabled, !item.keyEquivalent.isEmpty else { continue }
            var itemModifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            if item.keyEquivalent != item.keyEquivalent.lowercased() { itemModifiers.insert(.shift) }
            if item.keyEquivalent.lowercased() == key, itemModifiers == modifiers { return item }
        }
        return nil
    }

    func post(_ events: [NSEvent], window: NSWindow) async {
        for event in events { NSApp.postEvent(event, atStart: false) }
        await drain(window: window)
    }

    /// Returns once every previously posted event has been dispatched (or after 2 s).
    func drain(window: NSWindow) async {
        let marker = nextMarker
        nextMarker += 1
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, subtype: 0x0D06, data1: marker, data2: 0)
        else { return }
        await withCheckedContinuation { continuation in
            waiting[marker] = continuation
            NSApp.postEvent(event, atStart: false)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.waiting.removeValue(forKey: marker)?.resume()
            }
        }
    }
}
#endif
