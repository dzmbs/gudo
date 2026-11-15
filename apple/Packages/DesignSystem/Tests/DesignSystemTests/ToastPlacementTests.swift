#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
@Suite struct ToastPlacementTests {
    @Test func theInsetClearsOnlyTheCardsTheBannerWouldCover() {
        let host = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let banner = CGSize(width: 300, height: 40)
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: []) == 16)
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: [CGRect(x: 10, y: 600, width: 300, height: 90)]) == 108)
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: [CGRect(x: 600, y: 600, width: 300, height: 90)]) == 16)
        let stacked = [CGRect(x: 10, y: 600, width: 300, height: 90), CGRect(x: 20, y: 540, width: 300, height: 50)]
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: stacked) == 168)
    }

    @Test func atTheTopTheBannerDropsBelowTheCardsItWouldCover() {
        let host = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let banner = CGSize(width: 300, height: 40)
        let stack = CGRect(x: 604, y: 40, width: 380, height: 120)
        #expect(ToastCenter.topInset(base: 40, banner: banner, in: host, avoiding: []) == 40)
        #expect(ToastCenter.topInset(base: 40, banner: banner, in: host, avoiding: [stack]) == 168)
        #expect(ToastCenter.topInset(base: 40, banner: banner, in: host, avoiding: [CGRect(x: 10, y: 40, width: 300, height: 120)]) == 40)
        #expect(ToastCenter.bottomInset(base: 16, banner: banner, in: host, avoiding: [CGRect(x: 10, y: 600, width: 300, height: 90)], position: .bottomCenter) == 16)
    }

    @Test func toastsStartAtTheBottomLeadingCorner() {
        #expect(ToastPosition.standard == .bottomLeading)
        #expect(ToastPosition(rawValue: "") == nil)
        #expect(ToastPosition.allCases.map(\.rawValue) == ["bottom-leading", "top-trailing", "bottom-center"])
        #expect(ToastPosition.topTrailing.edge == .top)
        #expect(ToastPosition.bottomCenter.alignment == .bottom)
    }

    @Test(.serialized, arguments: ToastPosition.allCases)
    func eachPositionPutsTheBannerAtItsCorner(_ position: ToastPosition) async throws {
        let saved = UserDefaults.standard.object(forKey: ToastPosition.key)
        UserDefaults.standard.set(position.rawValue, forKey: ToastPosition.key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: ToastPosition.key) } else { UserDefaults.standard.removeObject(forKey: ToastPosition.key) }
        }
        let center = ToastCenter()
        center.show(Toast("Copied", systemImage: "doc.on.doc"))
        let renderer = ImageRenderer(content: Color.black.frame(width: 900, height: 600).toastHost(center)) // style-exempt: a black field to find the banner on
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let banner = try #require(Self.drawnBounds(image), "nothing drawn")
        switch position {
        case .bottomLeading:
            #expect(banner.midX < 300 && banner.midY > 450)
        case .topTrailing:
            #expect(banner.midX > 600 && banner.midY < 150)
        case .bottomCenter:
            #expect(abs(banner.midX - 450) < 4 && banner.midY > 450)
        }
    }

    /// The box around every pixel that is not black, top-left origin.
    private static func drawnBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bounds: CGRect?
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 60 else { continue }
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                bounds = bounds?.union(pixel) ?? pixel
            }
        }
        return bounds
    }

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
