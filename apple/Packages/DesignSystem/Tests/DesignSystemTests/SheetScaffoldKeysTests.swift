#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// A Mac sheet's default button answers ⌘↩ as well as Return: Return types a new line in a
/// multi-line field, ⌘↩ still confirms.
@MainActor
@Suite struct SheetScaffoldKeysTests {
    @Observable final class Presses {
        var count = 0
    }

    private struct Sheet: View {
        let presses: Presses
        var isEnabled = true
        var body: some View {
            SheetScaffold("Sheet", cancel: SheetAction("Cancel") {}, primary: SheetAction("Start", isEnabled: isEnabled) { presses.count += 1 }) {
                Text("Body")
            }
            .frame(width: 400, height: 300)
        }
    }

    private func commandReturn(in window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)
        else { return false }
        return window.performKeyEquivalent(with: event)
    }

    private func window(_ view: some View) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFrontRegardless()
        for _ in 0..<10 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        return window
    }

    @Test func commandReturnRunsTheDefaultButton() async throws {
        let presses = Presses()
        let window = try await window(Sheet(presses: presses))
        defer { window.close() }
        _ = commandReturn(in: window)
        #expect(presses.count == 1)
    }

    @Test func commandReturnLeavesADisabledButtonAlone() async throws {
        let presses = Presses()
        let window = try await window(Sheet(presses: presses, isEnabled: false))
        defer { window.close() }
        _ = commandReturn(in: window)
        #expect(presses.count == 0)
    }
}
#endif
