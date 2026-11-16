import PaneLayout
import SwiftUI
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An overlay that takes the keyboard (the palette, Go to Tab, a workflow panel, a sheet, the
/// host switcher, the rename prompt) keeps every key from the terminal behind it while it is up,
/// and gives the keyboard back to the pane that had it when it closes.
@MainActor
final class OverlayFocusTests: XCTestCase {
    #if os(macOS)
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var window: NSWindow!
    #else
    private var window: UIWindow!
    #endif
    private var model: WindowModel!
    /// The tab this test opened: closed again, so the shared local workspace is left as found.
    private var openedTab: (workspace: Workspace, tab: TabId)?

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
        let workspace = try XCTUnwrap(model.workspace)
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        openedTab = workspace.session.tabs.first { !before.contains($0.id) }.map { (workspace, $0.id) }
        await waitUntil { self.openedTab.map { workspace.session.activeTabId == $0.tab } == true }
        await waitUntil { (try? self.terminalView().window) != nil }
        let terminal = try terminalView()
        #if os(iOS)
        terminal.becomeFirstResponder()
        #endif
        await waitUntil { self.keyboardOwner === terminal }
    }

    override func tearDown() async throws {
        guard let model else { return }
        model.isPaletteShown = false
        model.sheet = nil
        if let openedTab { openedTab.workspace.apply(.closeTab(openedTab.tab)) }
        try? await Task.sleep(for: .seconds(0.3))
        #if os(macOS)
        window?.close()
        #else
        window?.isHidden = true
        window?.rootViewController = nil
        #endif
        model.close()
    }

    func testKeysTypedAsThePaletteOpensNeverReachThePane() async throws {
        let terminal = try terminalView()
        XCTAssertTrue(keyboardOwner === terminal, "keyboard: \(describeKeyboardOwner())")
        model.isPaletteShown = true
        XCTAssertFalse(keyboardOwner === terminal, "the pane gives up the keyboard as the palette opens")
        type("qzx")
        await waitUntil { self.paletteFieldHasKeyboard }
        XCTAssertTrue(paletteFieldHasKeyboard, "keyboard: \(describeKeyboardOwner())")
        type("zqx")
        await settle()
        XCTAssertFalse(screenText().contains("qzx"), "keys typed as the palette opened reached the shell")
        XCTAssertFalse(screenText().contains("zqx"), "keys typed into the palette reached the shell")
    }

    func testAPaneFocusedWhileThePaletteIsUpLeavesTheKeyboardWithThePalette() async throws {
        let workspace = try XCTUnwrap(model.workspace)
        model.isPaletteShown = true
        await waitUntil { self.paletteFieldHasKeyboard }
        WorkspaceAction.splitRight.perform(on: workspace, window: model)
        await waitUntil { (try? self.terminalView().window) != nil }
        await settle()
        XCTAssertTrue(paletteFieldHasKeyboard, "keyboard: \(describeKeyboardOwner())")
    }

    func testClosingThePaletteGivesTheKeyboardBackToThePane() async throws {
        let terminal = try terminalView()
        model.isPaletteShown = true
        await waitUntil { self.paletteFieldHasKeyboard }
        closePalette()
        await waitUntil { !self.model.isPaletteShown }
        XCTAssertTrue(keyboardOwner === terminal, "keyboard: \(describeKeyboardOwner())")
        await settle()
        XCTAssertTrue(keyboardOwner === terminal, "after the palette faded: \(describeKeyboardOwner())")
        type("qzx")
        await waitUntil { self.screenText().contains("qzx") }
        XCTAssertTrue(screenText().contains("qzx"), "the pane takes keys again")
    }

    func testClosingThePaletteAtOnceGivesTheKeyboardBackToThePane() async throws {
        let terminal = try terminalView()
        model.isPaletteShown = true
        model.isPaletteShown = false
        await settle()
        XCTAssertTrue(keyboardOwner === terminal, "keyboard: \(describeKeyboardOwner())")
    }

    func testClosingGoToTabGivesTheKeyboardBackToThePane() async throws {
        let terminal = try terminalView()
        WorkspaceAction.goToTab.perform(on: try XCTUnwrap(model.workspace), window: model)
        XCTAssertEqual(model.paletteMode, .goToTab)
        await waitUntil { self.paletteFieldHasKeyboard }
        type("qzx")
        closePalette()
        await settle()
        XCTAssertTrue(keyboardOwner === terminal, "keyboard: \(describeKeyboardOwner())")
        XCTAssertFalse(screenText().contains("qzx"))
    }

    func testEveryOverlayHoldsTheKeyboardAndGivesItBack() async throws {
        let terminal = try terminalView()
        let workspace = try XCTUnwrap(model.workspace)
        let tab = try XCTUnwrap(workspace.session.activeTabId)
        let overlays: [(String, (Bool) -> Void)] = [
            ("sheet", { self.model.sheet = $0 ? .shortcuts : nil }),
            ("host switcher", { self.model.isHostSwitcherShown = $0 }),
            ("rename prompt", { workspace.renamingTab = $0 ? tab : nil }),
        ]
        for (name, show) in overlays {
            show(true)
            await waitUntil { self.model.overlayHoldsKeyboard && self.keyboardOwner !== terminal }
            XCTAssertFalse(keyboardOwner === terminal, "\(name) open: the pane still has the keyboard")
            XCTAssertFalse(terminal.becomeFirstResponder(), "\(name) open: the pane takes the keyboard")
            show(false)
            await waitUntil { self.keyboardOwner === terminal }
            XCTAssertTrue(keyboardOwner === terminal, "\(name) closed: \(describeKeyboardOwner())")
        }
    }

    func testReturnToTerminalGivesTheKeyboardToTheFocusedPane() async throws {
        let terminal = try terminalView()
        #if os(macOS)
        window.makeFirstResponder(nil)
        #else
        terminal.resignFirstResponder()
        #endif
        XCTAssertFalse(keyboardOwner === terminal)
        WorkspaceAction.returnToTerminal.perform(on: try XCTUnwrap(model.workspace), window: model)
        XCTAssertTrue(keyboardOwner === terminal, "keyboard: \(describeKeyboardOwner())")
    }

    // MARK: Helpers

    private func terminalView() throws -> PlatformView {
        let workspace = try XCTUnwrap(model.workspace)
        let id = try XCTUnwrap(workspace.focusedPane)
        return try XCTUnwrap(workspace.pane(id)?.view)
    }

    /// Every pane of this test's tab.
    private func screenText() -> String {
        guard let workspace = model.workspace, let tab = workspace.session.tabs.first(where: { $0.id == openedTab?.tab }) else { return "" }
        return tab.root.panes.compactMap { workspace.pane($0)?.view.surface.terminal.visibleText() }.joined(separator: "\n")
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

    private var paletteFieldHasKeyboard: Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as? NSView)?.window === window && model.isPaletteShown
    }

    private func closePalette() {
        press("\u{1b}", keyCode: 53)
    }

    private static let keyCodes: [Character: UInt16] = ["q": 12, "x": 7, "z": 6]

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

    private var paletteFieldHasKeyboard: Bool {
        window.firstResponderWithin() is UITextField && model.isPaletteShown
    }

    private func closePalette() {
        model.isPaletteShown = false
    }

    /// Text as a hardware keyboard sends it, to whatever has the keyboard.
    private func type(_ text: String) {
        (window.firstResponderWithin() as? any UIKeyInput)?.insertText(text)
    }
    #endif
}
