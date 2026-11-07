import PaneLayout
import TerminalCore
import TerminalRenderer
import XCTest
import os
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class TerminalGeneratedInputTests: XCTestCase {
    private final class RecordingBackend: PaneBackend, @unchecked Sendable {
        let input = OSAllocatedUnfairLock(initialState: [[UInt8]]())
        let generated = OSAllocatedUnfairLock(initialState: [[UInt8]]())
        var hostAnswersQueries: Bool { false }
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {
            let bytes = Array(bytes)
            input.withLock { $0.append(bytes) }
        }
        func writeGenerated(_ bytes: UnsafeRawBufferPointer) {
            let bytes = Array(bytes)
            generated.withLock { $0.append(bytes) }
        }
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
    }

    func testUserPasteDoesNotTravelAsAGeneratedTerminalReply() throws {
        let backend = RecordingBackend()
        let pane = try Pane(id: PaneId(1), backend: backend, onExit: {})
        pane.view.surface.terminal.write(Array("\u{1b}[?2004h".utf8))
        XCTAssertEqual(pane.view.surface.paste("native paste"), .written)
        XCTAssertEqual(backend.input.withLock { $0 }, [Array("\u{1b}[200~native paste\u{1b}[201~".utf8)])
        XCTAssertTrue(backend.generated.withLock { $0.isEmpty })
    }

    func testVTQueriesStillUseTheGeneratedReplyPath() throws {
        let backend = RecordingBackend()
        let pane = try Pane(id: PaneId(1), backend: backend, onExit: {})
        pane.view.surface.terminal.write(Array("\u{1b}[5n".utf8))
        XCTAssertTrue(backend.input.withLock { $0.isEmpty })
        XCTAssertEqual(backend.generated.withLock { $0 }, [Array("\u{1b}[0n".utf8)])
    }

    func testAnUnconfirmedPasteDoesNotClaimUserActivity() throws {
        let backend = RecordingBackend()
        let pane = try Pane(id: PaneId(1), backend: backend, onExit: {})
        XCTAssertEqual(pane.view.surface.paste("line one\nline two"), .needsConfirmation)
        XCTAssertTrue(backend.input.withLock { $0.isEmpty })
        XCTAssertTrue(backend.generated.withLock { $0.isEmpty })
    }

    private func makeView(modes: String) throws -> TerminalView {
        let terminal = Terminal(cols: 40, rows: 10) { _ in }
        terminal.write(Array(modes.utf8))
        return TerminalView(surface: try TerminalSurface(terminal: terminal, appearance: .init()))
    }

    func testLocalEscapeDismissalConsumesTheKeyCycleButTheNextEscapeReachesTheAgent() throws {
        let view = try makeView(modes: "\u{1b}[>31u")
        var dismissals = 0
        view.onEscape = {
            guard dismissals == 0 else { return false }
            dismissals += 1
            return true
        }
        var typed: [[UInt8]] = [], generated: [[UInt8]] = []
        view.onInput = { typed.append($0) }
        view.onGeneratedInput = { generated.append($0) }
        let press = KeyEvent.press(.escape)
        view.send(press)
        var repeated = press
        repeated.action = .repeat
        view.send(repeated)
        var release = press
        release.action = .release
        view.send(release)
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(typed.isEmpty)
        XCTAssertTrue(generated.isEmpty)
        view.send(press)
        XCTAssertEqual(typed.count, 1)
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
