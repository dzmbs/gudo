import PaneLayout
import SwiftUI
import XCTest
@testable import App
#if os(macOS)
import AppKit
#endif

/// Dividers and window edges take hold of the pointer well before it is on the line, and a
/// terminal under a zone leaves the zone's resize pointer alone.
@MainActor
final class ResizeZoneTests: XCTestCase {
    func testADividerZoneStraddlesItsGap() {
        let line = CGRect(x: 400, y: 0, width: 1, height: 600)
        let zone = ResizeZones.divider(line, axis: .horizontal)
        #if os(macOS)
        XCTAssertEqual(zone.width, 13)
        XCTAssertTrue(zone.contains(CGPoint(x: 394.5, y: 300)), "6 pt left of the line")
        XCTAssertTrue(zone.contains(CGPoint(x: 406.5, y: 300)), "6 pt right of the line")
        XCTAssertFalse(zone.contains(CGPoint(x: 393, y: 300)))
        #else
        XCTAssertGreaterThanOrEqual(zone.width, 44, "a finger's target")
        #endif
        XCTAssertEqual(zone.midX, line.midX)
        XCTAssertEqual(ResizeZones.dividerThickness(gap: 1), zone.width)

        let row = ResizeZones.divider(CGRect(x: 0, y: 300, width: 800, height: 1), axis: .vertical)
        XCTAssertEqual(row.height, zone.width)
        XCTAssertEqual(row.width, 800)
    }

    func testAWindowIsHeldAllRoundMostlyOutside() {
        let frame = CGRect(x: 200, y: 100, width: 600, height: 400)
        let zones = ResizeZones.window(frame)
        XCTAssertEqual(zones.count, 8)
        let edge = ResizeZones.edgeOutside + ResizeZones.edgeInside
        #if os(macOS)
        XCTAssertGreaterThanOrEqual(ResizeZones.edgeOutside, 6)
        XCTAssertGreaterThan(ResizeZones.cornerOutside + ResizeZones.cornerInside, edge, "corners are larger")
        #else
        XCTAssertGreaterThanOrEqual(edge, 44)
        XCTAssertGreaterThanOrEqual(ResizeZones.cornerOutside + ResizeZones.cornerInside, 44)
        #endif
        XCTAssertGreaterThan(ResizeZones.edgeOutside, ResizeZones.edgeInside, "the header's buttons stay within reach")

        func edges(_ x: CGFloat, _ y: CGFloat) -> FloatGeometry.Edges? { ResizeZones.edges(at: CGPoint(x: x, y: y), in: zones) }
        let outside = ResizeZones.edgeOutside - 0.5, inside = ResizeZones.edgeInside - 0.5
        XCTAssertEqual(edges(frame.minX - outside, frame.midY), [.left])
        XCTAssertEqual(edges(frame.minX + inside, frame.midY), [.left])
        XCTAssertEqual(edges(frame.maxX + outside, frame.midY), [.right])
        XCTAssertEqual(edges(frame.midX, frame.minY - outside), [.top])
        XCTAssertEqual(edges(frame.midX, frame.maxY + outside), [.bottom])
        XCTAssertEqual(edges(frame.minX - 2, frame.minY - 2), [.left, .top])
        XCTAssertEqual(edges(frame.maxX + 2, frame.maxY + 2), [.right, .bottom])
        XCTAssertEqual(edges(frame.maxX - 2, frame.minY + 2), [.right, .top])
        XCTAssertEqual(edges(frame.minX + 2, frame.maxY - 2), [.left, .bottom])
        XCTAssertNil(edges(frame.midX, frame.midY), "the content is the window's")
        XCTAssertNil(edges(frame.minX + ResizeZones.edgeInside + 1, frame.midY))
        XCTAssertNil(edges(frame.minX - ResizeZones.edgeOutside - 1, frame.midY))

        // Every point along the border is in a zone: no gap between an edge and its corners.
        for t in stride(from: 0.0, through: 1.0, by: 0.01) {
            XCTAssertNotNil(edges(frame.minX + frame.width * t, frame.minY))
            XCTAssertNotNil(edges(frame.minX, frame.minY + frame.height * t))
            XCTAssertNotNil(edges(frame.maxX, frame.minY + frame.height * t))
            XCTAssertNotNil(edges(frame.minX + frame.width * t, frame.maxY))
        }
    }

    #if os(macOS)
    private final class Content: NSView {}

    private struct Hosted: NSViewRepresentable {
        let view: Content
        func makeNSView(context: Context) -> Content { view }
        func updateNSView(_ view: Content, context: Context) {}
    }

    /// The terminal sets its pointer only where a click would land on it: a zone drawn over its
    /// edge is the hit there, so the zone's resize pointer stays.
    func testAZoneOverAPlatformViewIsTheHitThere() throws {
        let content = Content()
        let line = CGRect(x: 300, y: 0, width: 1, height: 400)
        let zone = ResizeZones.divider(line, axis: .horizontal)
        let root = ZStack(alignment: .topLeading) {
            Hosted(view: content)
            Color.clear
                .frame(width: zone.width, height: zone.height)
                .contentShape(.rect)
                .pointerStyle(.columnResize)
                .offset(x: zone.minX)
        }
        .frame(width: 600, height: 400)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let frameView = try XCTUnwrap(hosting.superview)

        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? {
            frameView.hitTest(hosting.convert(CGPoint(x: x, y: y), to: nil))
        }
        XCTAssertTrue(hit(150, 200) === content, "the content away from the zone")
        XCTAssertFalse(hit(zone.minX + 1, 200) === content, "the zone's leading side, over the content")
        XCTAssertFalse(hit(zone.maxX - 1, 200) === content)
        XCTAssertTrue(hit(zone.maxX + 2, 200) === content)
        _ = window
    }
    #endif
}
