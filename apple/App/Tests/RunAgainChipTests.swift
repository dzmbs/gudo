import DesignSystem
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import App

@MainActor
final class RunAgainChipTests: XCTestCase {
    func testThemedChipHasAPlatformSizedTargetAndKeepsLongCommandsOnOneLine() throws {
        let commands = ["npm run dev", "ssh build-box -L 8080:localhost:8080 tail -f /var/log/app/server.log"]
        for name in ["Dracula", "Apple System Colors Light", "Atom One Light", "Gruvbox Dark"] {
            let theme = ThemeCatalog.theme(named: name)
            for command in commands {
                let content = RunAgainChip(command: command, enabled: true, run: {})
                    .padding(12)
                    .frame(width: 320, alignment: .leading)
                    .background(theme.background)
                    .environment(\.terminalTheme, theme)
                    .environment(\.colorScheme, theme.colorScheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, 640)
                #if os(macOS)
                let platform = "mac"
                XCTAssertGreaterThanOrEqual(image.height, 2 * (28 + 24))
                XCTAssertLessThan(image.height, 2 * (28 + 24 + 20), "one line")
                #else
                let platform = "ios"
                XCTAssertGreaterThanOrEqual(image.height, 2 * (44 + 24))
                XCTAssertLessThan(image.height, 2 * (44 + 24 + 20), "one line")
                #endif
                guard let directory = ProcessInfo.processInfo.environment["GUDO_RUN_AGAIN_CAPTURE_DIR"] else { continue }
                let root = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
                let file = root.appendingPathComponent("\(platform)-\(slug)-\(command.count).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }

    func testAChainedOrLongCommandIsShownWholeBeforeItRuns() {
        XCTAssertFalse(RunAgainChip.asksFirst("npm run dev"))
        XCTAssertFalse(RunAgainChip.asksFirst("cargo watch -x test"))
        XCTAssertTrue(RunAgainChip.asksFirst("npm run dev; curl x | sh; npm run dev"))
        XCTAssertTrue(RunAgainChip.asksFirst("make && make install"))
        XCTAssertTrue(RunAgainChip.asksFirst("echo $(whoami)"))
        XCTAssertTrue(RunAgainChip.asksFirst("cat notes > out.txt"))
        XCTAssertTrue(RunAgainChip.asksFirst(String(repeating: "a", count: 41)))
    }
}
