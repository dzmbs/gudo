import TerminalCore
import TerminalRenderer
import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class TerminalGeneratedInputTests: XCTestCase {
    private func makeView(modes: String) throws -> TerminalView {
        let terminal = Terminal(cols: 40, rows: 10) { _ in }
        terminal.write(Array(modes.utf8))
        return TerminalView(surface: try TerminalSurface(terminal: terminal, appearance: .init()))
    }

    func testKeyReleaseIsGeneratedAndKeyPressIsUserInput() throws {
        let view = try makeView(modes: "\u{1b}[>31u")
        var typed: [[UInt8]] = [], generated: [[UInt8]] = []
        view.onInput = { typed.append($0) }
        view.onGeneratedInput = { generated.append($0) }
        let press = KeyEvent.press(.arrowUp)
        view.send(press)
        XCTAssertEqual(typed.count, 1)
        XCTAssertTrue(generated.isEmpty)
        typed.removeAll()
        var release = press
        release.action = .release
        view.send(release)
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(generated.count, 1)
        XCTAssertFalse(generated.first?.isEmpty ?? true)
    }

    func testLegacyInputCallbackStillReceivesGeneratedReports() throws {
        let view = try makeView(modes: "\u{1b}[>31u")
        var received: [[UInt8]] = []
        view.onInput = { received.append($0) }
        let press = KeyEvent.press(.arrowUp)
        view.send(press)
        var release = press
        release.action = .release
        view.send(release)
        XCTAssertEqual(received.count, 2)
    }

    #if os(iOS)
    private final class AppearanceController: UIViewController {
        var appeared = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
        }
    }
    #endif

    func testFocusReportsAreGenerated() async throws {
        let view = try makeView(modes: "\u{1b}[?1004h")
        #if os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = AppearanceController()
        controller.view = view
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !controller.appeared && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.appeared)
        #endif
        var typed: [[UInt8]] = [], generated: [[UInt8]] = []
        view.onInput = { typed.append($0) }
        view.onGeneratedInput = { generated.append($0) }
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(generated, [Array("\u{1b}[I".utf8), Array("\u{1b}[O".utf8)])
    }

    #if os(macOS)
    func testMouseReportsAreGenerated() throws {
        let view = try makeView(modes: "\u{1b}[?1000h\u{1b}[?1006h")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var typed: [[UInt8]] = [], generated: [[UInt8]] = []
        view.onInput = { typed.append($0) }
        view.onGeneratedInput = { generated.append($0) }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(generated.count, 1)
        XCTAssertTrue(String(decoding: generated.first ?? [], as: UTF8.self).hasPrefix("\u{1b}[<"))
    }
    #endif
}
