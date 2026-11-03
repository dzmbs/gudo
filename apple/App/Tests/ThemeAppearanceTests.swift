#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import XCTest
@testable import App

/// Native controls in a sheet draw in the theme's scheme, whatever the system's, and follow a
/// live theme change.
@MainActor
final class ThemeAppearanceTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        UserDefaults.standard.removeObject(forKey: TerminalPreferences.Key.theme)
        NSApp.appearance = nil
    }

    private func pump(_ seconds: Double = 1) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// The SSH sheet's "Sign In With" pop-up, as the app presents it.
    private func presentPairingSheet() async throws -> NSView {
        let model = WindowModel(app: .shared)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ThemedRoot {
            Color.clear.sheet(isPresented: .constant(true)) {
                ThemedRoot {
                    PairingSheet(directory: model.hosts, live: model.app.hosts, initialMode: .ssh, destination: "")
                        .environment(model).environment(model.app)
                }
            }
        })
        window.orderFrontRegardless()
        self.window = window
        await pump(1.5)
        let sheet = try XCTUnwrap(window.attachedSheet, "the sheet opens")
        // The form makes rows as they scroll in: Sign In is below the fold.
        let scroll = try XCTUnwrap(scrollView(in: sheet.contentView!))
        scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView!.bounds.maxY))
        await pump()
        return try XCTUnwrap(popUp(in: sheet.contentView!.superview!), "the pop-up is drawn")
    }

    private func popUp(in view: NSView) -> NSView? {
        if let button = view as? NSPopUpButton { return button }
        return view.subviews.lazy.compactMap { self.popUp(in: $0) }.first
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func isDark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func testSheetControlsTakeTheThemesScheme() async throws {
        let dark = try XCTUnwrap(ThemeCatalog.all.first { !$0.isLight })
        let light = try XCTUnwrap(ThemeCatalog.all.first(where: \.isLight))

        UserDefaults.standard.set(dark.name, forKey: TerminalPreferences.Key.theme)
        let button = try await presentPairingSheet()
        XCTAssertTrue(isDark(button), "a dark theme draws its controls dark")

        UserDefaults.standard.set(light.name, forKey: TerminalPreferences.Key.theme)
        await pump()
        XCTAssertFalse(isDark(button), "a light theme draws them light")

        UserDefaults.standard.set(dark.name, forKey: TerminalPreferences.Key.theme)
        await pump()
        XCTAssertTrue(isDark(button), "and back, live")
    }
}
#endif
