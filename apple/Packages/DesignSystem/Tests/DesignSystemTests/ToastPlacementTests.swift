#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

/// A banner rises above cards at the bottom of a pane (someone's draft) instead of covering them.
@MainActor
@Suite struct ToastPlacementTests {
    @Test func theInsetClearsOnlyTheCardsTheBannerWouldCover() {
        let host = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let banner = CGSize(width: 300, height: 40)
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: []) == 16)
        // A card in the left pane, away from the centred banner: no change.
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: [CGRect(x: 10, y: 600, width: 300, height: 90)]) == 16)
        // Under the banner: it sits 8 above the card's top.
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: [CGRect(x: 300, y: 600, width: 500, height: 90)]) == 108)
        // Two stacked cards: above both.
        let stacked = [CGRect(x: 300, y: 600, width: 500, height: 90), CGRect(x: 400, y: 540, width: 300, height: 50)]
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: stacked) == 168)
    }

    /// Laid out for real: a card marked as an obstacle reports its frame to the window's
    /// banners, so the banner's inset clears it.
    @Test func aDraftCardReportsItselfToTheBanners() async throws {
        let center = ToastCenter()
        var card = CGRect.zero
        let root = ZStack(alignment: .bottom) {
            Color.black
            Text("Kim is writing: deploy the staging branch and run the migrations")
                .padding(DS.Space.m)
                .frame(maxWidth: 640)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { card = $0 }
                .toastObstacle()
                .padding(DS.Space.s)
        }
        .toastHost(center)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        center.show(Toast("Stopped following Kim", systemImage: "eye.slash"))
        for _ in 0..<5 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!card.isEmpty)
        #expect(Array(center.obstacles.values) == [card])
        let inset = ToastCenter.bottomInset(
            base: DS.Space.l, banner: CGSize(width: 300, height: 40), in: CGRect(x: 0, y: 0, width: 900, height: 600),
            avoiding: Array(center.obstacles.values))
        #expect(600 - inset <= card.minY, "the banner's bottom is above the card")
    }
}
#endif
