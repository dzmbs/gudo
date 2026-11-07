import DesignSystem
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class PlacementControlsTests: XCTestCase {
    func testNativeCloseControlsExposeAnAccessibleRemoveAction() {
        let marker = PlacementMarker(frame: .zero)
        marker.setIdentifier("placement-test", label: "Drawing")
        marker.setImageFrame(CGRect(x: 20, y: 20, width: 100, height: 80), viewport: CGRect(x: 0, y: 0, width: 300, height: 600))
        #if os(macOS)
        XCTAssertEqual(marker.closeButton.frame.width, 28)
        XCTAssertEqual(marker.closeButton.accessibilityLabel(), "Remove image from terminal")
        #else
        XCTAssertEqual(marker.closeButton.frame.width, 44)
        XCTAssertEqual(marker.closeButton.accessibilityLabel, "Remove image from terminal")
        #endif
    }

    func testCloseAffordanceFollowsDarkAndLightPalettes() throws {
        guard let directory = ProcessInfo.processInfo.environment["GUDO_PLACEMENT_CAPTURE_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in ["Dracula", "Apple System Colors Light"] {
            let theme = ThemeCatalog.theme(named: name), palette = ChromePalette(theme: ThemeCatalog.theme(named: name))
            let imageRect = CGRect(x: 40, y: 30, width: 200, height: 140)
            let marker = PlacementMarker(frame: .zero)
            marker.setImageFrame(imageRect, viewport: CGRect(x: 0, y: 0, width: 300, height: 200))
            marker.setPalette(palette)
            #if os(macOS)
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
            root.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor(palette.background.color).cgColor
            let photo = NSImageView(frame: imageRect)
            photo.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            photo.imageScaling = .scaleProportionallyUpOrDown
            photo.contentTintColor = NSColor(palette.accent.color)
            root.addSubview(photo)
            root.addSubview(marker)
            root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let platform = "mac"
            #else
            let root = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
            root.overrideUserInterfaceStyle = theme.isLight ? .light : .dark
            root.backgroundColor = UIColor(palette.background.color)
            let photo = UIImageView(frame: imageRect)
            photo.image = UIImage(systemName: "photo")
            photo.contentMode = .scaleAspectFit
            photo.tintColor = UIColor(palette.accent.color)
            root.addSubview(photo)
            root.addSubview(marker)
            root.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: root.bounds).image { context in root.layer.render(in: context.cgContext) }
            let png = try XCTUnwrap(image.pngData())
            let platform = "ios"
            #endif
            try png.write(to: output.appendingPathComponent("\(platform)-\(theme.isLight ? "light" : "dark").png"))
        }
    }

    func testTinyPlacementsKeepA44PointCloseTargetInsideTheViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 300, height: 600)
        for x in [0.0, 296.0] {
            for y in [0.0, 596.0] {
                let image = CGRect(x: x, y: y, width: 4, height: 4)
                let layout = PlacementControlLayout(image: image, viewport: viewport, target: 44)
                XCTAssertEqual(layout.close.width, 44)
                XCTAssertEqual(layout.close.height, 44)
                let close = layout.close.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)
                XCTAssertTrue(viewport.contains(close))
                XCTAssertTrue(layout.frame.contains(image))
                XCTAssertTrue(CGRect(origin: .zero, size: layout.frame.size).contains(layout.close))
            }
        }
    }

    func testNormalImageKeepsItsFrameAndPutsCloseAtTheTopTrailingCorner() {
        let image = CGRect(x: 60, y: 100, width: 120, height: 80)
        let layout = PlacementControlLayout(image: image, viewport: CGRect(x: 0, y: 0, width: 300, height: 600), target: 44)
        XCTAssertEqual(layout.frame, image)
        XCTAssertEqual(layout.close, CGRect(x: 76, y: 0, width: 44, height: 44))
    }
}
