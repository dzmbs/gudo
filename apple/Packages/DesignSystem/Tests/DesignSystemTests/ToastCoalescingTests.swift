import Testing
@testable import DesignSystem

/// The same toast shown again stays the one on screen instead of stacking a fresh copy.
@MainActor
@Suite struct ToastCoalescingTests {
    @Test func theSameToastAgainKeepsTheOneOnScreen() {
        let center = ToastCenter()
        center.show(Toast("Copied", systemImage: "doc.on.doc", style: .success))
        let shown = center.current?.id
        center.show(Toast("Copied", systemImage: "doc.on.doc", style: .success))
        #expect(center.current?.id == shown)
    }

    @Test func aDifferentToastReplacesIt() {
        let center = ToastCenter()
        center.show(Toast("Copied", style: .success))
        let shown = center.current?.id
        center.show(Toast("Couldn't copy", style: .failure))
        #expect(center.current?.id != shown)
        #expect(center.current?.message == "Couldn't copy")
    }

    @Test func aRepeatTakesTheNewestAction() {
        let center = ToastCenter()
        var undone: [Int] = []
        center.show(Toast("Closed tab", action: .init("Undo") { undone.append(1) }))
        center.show(Toast("Closed tab", action: .init("Undo") { undone.append(2) }))
        center.current?.action?.perform()
        #expect(undone == [2])
    }

    @Test func styleAndActionTellToastsApart() {
        #expect(!Toast("Saved", style: .success).repeats(Toast("Saved", style: .neutral)))
        #expect(!Toast("Closed tab").repeats(Toast("Closed tab", action: .init("Undo") {})))
        #expect(Toast("Saved").repeats(Toast("Saved")))
    }
}
