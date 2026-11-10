import SwiftUI
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The find bar and the terminal share the keyboard: a click in the terminal types into the pane
/// while the bar stays open, ⌘F goes back to the field, Esc in the field closes the bar.
@MainActor
final class PaneSearchFocusTests: XCTestCase {
    #if os(macOS)
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var window: NSWindow!
    #else
    private var window: UIWindow!
    #endif
    private var model: WindowModel!

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        model = WindowModel(app: .shared)
        model.start()
        let root = WindowContent(request: nil, model: model).environment(AppModel.shared)
        #if os(macOS)
        let frame = NSRect(x: -30000, y: -30000, width: 1000, height: 700)
        window = OffscreenWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        #endif
        await waitUntil { self.model.workspace?.focusedPane != nil }
        await waitUntil { (try? self.terminalView().window) != nil }
        _ = try terminalView()
    }

    override func tearDown() async throws {
        guard let model else { return }
        model.isSearchShown = false
        try? await Task.sleep(for: .seconds(0.3))
        #if os(macOS)
        window?.close()
        #else
        window?.isHidden = true
        window?.rootViewController = nil
        #endif
        model.close()
    }

    func testClickingTheTerminalWithTheBarOpenTypesIntoThePane() async throws {
        let terminal = try terminalView()
        await openSearch()
        type("e")
        await waitUntil { self.model.searchNeedle == "e" }
        XCTAssertEqual(model.searchNeedle, "e", "typing in the field searches")

        click(terminal)
        await settle()
        XCTAssertTrue(keyboardOwner === terminal, "keyboard: \(describeKeyboardOwner())")
        XCTAssertTrue(model.isSearchShown, "the bar stays open")

        type("qzx")
        await waitUntil { self.screenText().contains("qzx") }
        XCTAssertEqual(model.searchNeedle, "e", "the keys went to the pane, not the field")
        XCTAssertTrue(screenText().contains("qzx"), "the pane echoed the keys")
        XCTAssertTrue(keyboardOwner === terminal)
    }

    func testClickingAnotherSplitWithTheBarOpenTypesIntoThatPane() async throws {
        let workspace = try XCTUnwrap(model.workspace)
        let first = try terminalView()
        WorkspaceAction.splitRight.perform(on: workspace, window: model)
        await waitUntil { (try? self.terminalView()) !== first && (try? self.terminalView().window) != nil }
        await settle()
        await openSearch()

        click(first)
        await settle()
        XCTAssertTrue(keyboardOwner === first, "keyboard: \(describeKeyboardOwner())")
        XCTAssertTrue(model.isSearchShown, "the bar stays open")
        type("qzx")
        await waitUntil { self.screenText().contains("qzx") }
        XCTAssertEqual(model.searchNeedle, "", "the keys went to the pane, not the field")
    }

    func testTheBarShownAgainLeavesTheKeyboardInTheTerminal() async throws {
        let workspace = try XCTUnwrap(model.workspace)
        WorkspaceAction.splitRight.perform(on: workspace, window: model)
        await waitUntil { (try? self.terminalView().window) != nil }
        await settle()
        let terminal = try terminalView()
        await openSearch()
        click(terminal)
        await settle()
        XCTAssertTrue(keyboardOwner === terminal)

        WorkspaceAction.toggleZoom.perform(on: workspace, window: model)
        await settle()
        XCTAssertTrue(keyboardOwner === terminal, "zoomed in: \(describeKeyboardOwner())")
        WorkspaceAction.toggleZoom.perform(on: workspace, window: model)
        await settle()
        XCTAssertTrue(keyboardOwner === terminal, "zoomed out: \(describeKeyboardOwner())")
        XCTAssertTrue(model.isSearchShown, "the bar stays open")
    }

    func testANewTabWithTheBarOpenTakesTheKeyboard() async throws {
        let workspace = try XCTUnwrap(model.workspace)
        let first = try terminalView()
        await openSearch()
        WorkspaceAction.newTab.perform(on: workspace, window: model)
        await waitUntil { (try? self.terminalView()) !== first && (try? self.terminalView().window) != nil }
        await settle()
        XCTAssertTrue(keyboardOwner === (try terminalView()), "keyboard: \(describeKeyboardOwner())")
    }

    func testFindWithTheBarOpenPutsTheKeyboardBackInTheField() async throws {
        let terminal = try terminalView()
        await openSearch()
        click(terminal)
        await waitUntil { self.keyboardOwner === terminal }
        await settle()
        XCTAssertTrue(keyboardOwner === terminal)

        WorkspaceAction.find.perform(on: try XCTUnwrap(model.workspace), window: model)
        await waitUntil { self.fieldHasKeyboard }
        XCTAssertTrue(fieldHasKeyboard, "keyboard: \(describeKeyboardOwner())")
    }

    #if os(macOS)
    func testEscapeInTheFieldClosesTheBarAndTheTerminalTakesTheKeyboard() async throws {
        let terminal = try terminalView()
        await openSearch()
        press("\u{1b}", keyCode: 53)
        await waitUntil { !self.model.isSearchShown }
        await settle()
        XCTAssertFalse(model.isSearchShown)
        XCTAssertTrue(keyboardOwner === terminal, "keyboard: \(describeKeyboardOwner())")
    }
    #endif

    // MARK: Helpers

    private func terminalView() throws -> PlatformView {
        let workspace = try XCTUnwrap(model.workspace)
        let id = try XCTUnwrap(workspace.focusedPane)
        return try XCTUnwrap(workspace.pane(id)?.view)
    }

    private func screenText() -> String {
        guard let workspace = model.workspace, let id = workspace.focusedPane else { return "" }
        return workspace.pane(id)?.view.surface.terminal.visibleText() ?? ""
    }

    private func openSearch() async {
        WorkspaceAction.find.perform(on: model.workspace!, window: model)
        await waitUntil { self.fieldHasKeyboard }
        XCTAssertTrue(fieldHasKeyboard, "⌘F puts the keyboard in the field")
    }

    private func waitUntil(seconds: Double = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The window and its views settle for a few frames.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func describeKeyboardOwner() -> String {
        keyboardOwner.map { "\(Swift.type(of: $0))" } ?? "nothing"
    }

    #if os(macOS)
    private var keyboardOwner: AnyObject? { window.firstResponder }

    private var fieldHasKeyboard: Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as? NSTextField)?.placeholderString == "Search"
    }

    /// A click where the pointer lands over `view`. The window is never key (a test must not take
    /// the keyboard from the app in front), and AppKit gives a non-key window's first click to the
    /// window alone, so the click goes straight to the view the hit test finds.
    private func click(_ view: NSView) {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.maxY - 40), to: nil)
        let hit = window.contentView?.superview?.hitTest(point)
        XCTAssertTrue(hit?.isDescendant(of: view) == true, "the click lands on \(hit.map { "\(Swift.type(of: $0))" } ?? "nothing")")
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: eventType, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            if eventType == .leftMouseDown { hit?.mouseDown(with: event) } else { hit?.mouseUp(with: event) }
        }
    }

    private static let keyCodes: [Character: UInt16] = ["e": 14, "q": 12, "x": 7, "z": 6]

    /// Keys as the window delivers them, to whatever has the keyboard.
    private func type(_ text: String) {
        for character in text {
            press(String(character), keyCode: Self.keyCodes[character] ?? 0)
        }
    }

    private func press(_ characters: String, keyCode: UInt16) {
        for eventType in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: eventType, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            if let event { window.sendEvent(event) }
        }
    }
    #else
    private var keyboardOwner: UIView? { window.firstResponderWithin() }

    private var fieldHasKeyboard: Bool {
        (window.firstResponderWithin() as? UITextField)?.placeholder == "Search"
    }

    /// A tap where the finger lands over `view`: the terminal's tap takes the keyboard.
    private func click(_ view: UIView) {
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.maxY - 40), to: window)
        let hit = window.hitTest(point, with: nil)
        XCTAssertTrue(hit?.isDescendant(of: view) == true, "the tap lands on \(hit.map { "\(Swift.type(of: $0))" } ?? "nothing")")
        view.becomeFirstResponder()
    }

    /// Text as a hardware keyboard sends it, to whatever has the keyboard.
    private func type(_ text: String) {
        (window.firstResponderWithin() as? any UIKeyInput)?.insertText(text)
    }
    #endif
}
