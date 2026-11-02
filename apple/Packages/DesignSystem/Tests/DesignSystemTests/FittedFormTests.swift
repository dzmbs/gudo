#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// A fitted Mac form sheet opens at its final size: rows a host sends later scroll inside it,
/// and only the user's steps resize it.
@MainActor
@Suite struct FittedFormTests {
    @Observable final class Rows {
        var count = 2
        var step = 0
    }

    private struct Sheet: View {
        let rows: Rows
        var body: some View {
            Form {
                Section {
                    ForEach(0..<rows.count, id: \.self) { Text("Row \($0)") }
                }
            }
            .formStyle(.grouped)
            .macFittedForm(maxHeight: 560, step: rows.step)
            .frame(width: 400)
        }
    }

    private func settle(_ view: NSView, for duration: Duration) async throws {
        let end = ContinuousClock.now + duration
        while ContinuousClock.now < end {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func rowsArrivingLaterDoNotGrowTheSheet() async throws {
        let rows = Rows()
        let hosting = NSHostingView(rootView: Sheet(rows: rows))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 700)
        try await settle(hosting, for: .milliseconds(150))
        let opened = hosting.fittingSize.height
        #expect(opened > 0 && opened < 300, "as tall as two rows: \(opened)")

        // Past the opening: the host's answer adds rows; the sheet keeps its height.
        try await settle(hosting, for: .milliseconds(300))
        rows.count = 6
        try await settle(hosting, for: .milliseconds(150))
        #expect(hosting.fittingSize.height == opened)

        // The user's step: the sheet takes the rows' height.
        rows.step = 1
        rows.count = 7
        try await settle(hosting, for: .milliseconds(150))
        #expect(hosting.fittingSize.height > opened + 50, "\(hosting.fittingSize.height) after a step, \(opened) before")
    }
}
#endif
