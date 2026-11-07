import DesignSystem
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import App

@MainActor
final class PaneSizingChipTests: XCTestCase {
    func testThemedChipHasAPlatformSizedTarget() throws {
        for name in ["Dracula", "Apple System Colors Light"] {
            let theme = ThemeCatalog.theme(named: name)
            XCTAssertEqual(theme.name, name)
            XCTAssertEqual(theme.isLight, name.contains("Light"))
            let content = PaneSizingChip(label: "Sized for iPhone", enabled: true, useSize: {})
                .padding(12)
                .frame(width: 320)
                .background(theme.background)
                .environment(\.terminalTheme, theme)
                .environment(\.colorScheme, theme.colorScheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 640)
            #if os(macOS)
            let platform = "mac"
            XCTAssertGreaterThanOrEqual(image.height, 104)
            #else
            let platform = "ios"
            XCTAssertGreaterThanOrEqual(image.height, 136)
            #endif
            guard let directory = ProcessInfo.processInfo.environment["GUDO_SIZING_CHIP_CAPTURE_DIR"] else { continue }
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("\(platform)-\(theme.isLight ? "light" : "dark").png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
    }
}
