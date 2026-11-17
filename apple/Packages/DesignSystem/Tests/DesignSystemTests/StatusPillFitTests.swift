import SwiftUI
import Testing
@testable import DesignSystem
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A state's pill keeps its words on one line in a row with no room left (a long title beside
/// it at a large text size): it never wraps a letter per line.
@MainActor
@Suite struct StatusPillFitTests {
    private func size(_ view: some View, width: CGFloat) -> CGSize {
        #if os(macOS)
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 1_000))
        #else
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 1_000))
        #endif
    }

    @Test func pillsKeepOneLineWhereARowLeavesThemNoRoom() {
        let pills: [(String, AnyView)] = [
            ("status", AnyView(StatusPill(.error))),
            ("status with detail", AnyView(StatusPill(.error, detail: "exit 101"))),
            ("state", AnyView(StatePill(.error))),
        ]
        for (name, pill) in pills {
            let natural = size(pill, width: 1_000)
            let squeezed = size(pill, width: 12)
            #expect(squeezed.height == natural.height, "\(name): \(natural) squeezed to \(squeezed)")
        }
    }
}
