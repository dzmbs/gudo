#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import XCTest
@testable import App

/// The Settings window as it opens: the panes list holds the keyboard, not the search field, so
/// no focus ring shows until the search is clicked or ⌘F is pressed.
@MainActor
final class SettingsWindowTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func testSettingsOpensWithoutTheSearchFieldFocused() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "renders the mock app")
        let size = CGSize(width: 820, height: 560)
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        let controller = NSHostingController(rootView: ThemedRoot { SettingsView() })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(NSRect(x: -30000, y: -30000, width: size.width, height: size.height), display: false)
        window.orderFrontRegardless()
        defer { window.close() }
        await pump(1.5)
        XCTAssertFalse(window.firstResponder is NSText, "the search field took the keyboard as Settings opened: \(String(describing: window.firstResponder))")
    }

    /// A click or a key still puts the keyboard in the search.
    func testOnlyTheUsersClickOrKeyFocusesTheSearch() throws {
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let key = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(SettingsView.isUserEvent(click))
        XCTAssertTrue(SettingsView.isUserEvent(key))
        XCTAssertFalse(SettingsView.isUserEvent(nil), "a window settling its keyboard")
    }
}
#endif
