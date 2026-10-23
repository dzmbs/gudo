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
    static func `for`(_ page: WebPage) async -> BrowserNativeInput? {
        let token = UUID().uuidString
        do {
            _ = try await page.callJavaScript("window.__unInputToken = token", arguments: ["token": token], contentWorld: world)
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

    // MARK: Keys

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
    static func `for`(_ page: WebPage) async -> BrowserNativeInput? { nil }
    #endif
}
