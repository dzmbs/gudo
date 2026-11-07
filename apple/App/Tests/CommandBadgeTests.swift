import DesignSystem
import TerminalCore
import TerminalRenderer
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class CommandBadgeTests: XCTestCase {
    func testStickyCommandWith200ListingLinesStaysOneLineAndKeepsOnlyItsLeadingText() throws {
        #if os(macOS)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #else
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        #endif
        let palette = ChromePalette(theme: ThemeCatalog.theme(named: "Dracula"))
        let badge = CommandBadge(identifier: "command-sticky-test", sticky: true)
        badge.show("$ cp Downloads/x", color: palette.textSecondary, palette: palette, in: root)
        badge.place(leading: 8, top: 2, maxWidth: 384, in: root)
        let label = try XCTUnwrap(root.subviews.first)
        let height = label.frame.height
        let listing = (0..<200).map { "download-\($0).txt" }.joined(separator: "\n")
        badge.show("$ cp Downloads/x\n" + listing, color: palette.textSecondary, palette: palette, in: root)
        badge.place(leading: 8, top: 2, maxWidth: 384, in: root)
        XCTAssertEqual(label.frame.height, height, accuracy: 0.01)
        XCTAssertLessThanOrEqual(label.frame.maxX, 384)
        #if os(macOS)
        let field = try XCTUnwrap(label as? NSTextField)
        XCTAssertEqual(field.stringValue.trimmingCharacters(in: .whitespaces), "$ cp Downloads/x")
        XCTAssertEqual(field.maximumNumberOfLines, 1)
        #else
        let field = try XCTUnwrap(label as? UILabel)
        XCTAssertEqual(field.text, "$ cp Downloads/x")
        XCTAssertEqual(field.numberOfLines, 1)
        #endif
    }

    func testRealZshCompletionSnapshotsWithNativeSingleLineHeader() throws {
        guard let directory = ProcessInfo.processInfo.environment["GUDO_SHELL_CAPTURE_DIR"] else {
            throw XCTSkip("Run the isolated zsh theme/completion fixture with GUDO_SHELL_CAPTURE_DIR first")
        }
        let rootURL = URL(fileURLWithPath: directory, isDirectory: true)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: rootURL.appendingPathComponent("commands.json"))) as? [[String: Any]])
        let command = try XCTUnwrap(metadata.last?["command"] as? String)
        let output = rootURL.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for stage in ["listing", "output"] {
            for name in ["Dracula", "Apple System Colors Light"] {
                let theme = ThemeCatalog.theme(named: name), palette = ChromePalette(theme: ThemeCatalog.theme(named: name))
                let snapshot = try Data(contentsOf: rootURL.appendingPathComponent("zsh-\(stage).snapshot"))
                let parts = try XCTUnwrap(Terminal.splitSnapshot(snapshot))
                let terminal = Terminal(cols: 100, rows: 30) { _ in }
                try terminal.restore(snapshot: parts.ready)
                var appearance = TerminalAppearance()
                appearance.background = RGB(hex: theme.bg)
                appearance.foreground = RGB(hex: theme.fg)
                appearance.palette = RGB.palette(ansi: theme.palette.map(RGB.init(hex:)))
                appearance.paddingBalance = true
                terminal.setDefaults(appearance.terminalConfiguration)
                let surface = try TerminalSurface(terminal: terminal, appearance: appearance)
                surface.sizeFollowsStream = true
                let size = CGSize(width: 900, height: 500)
                surface.layout(size: size, scale: 2)
                surface.outputArrived()
                XCTAssertTrue(surface.renderIfDirty(offscreen: true))
                let rendered = try XCTUnwrap(surface.snapshot())
                #if os(macOS)
                let root = CommandCaptureView(frame: CGRect(origin: .zero, size: size))
                root.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
                let image = NSImageView(frame: root.bounds)
                image.image = NSImage(cgImage: rendered, size: size)
                root.addSubview(image)
                #else
                let root = UIView(frame: CGRect(origin: .zero, size: size))
                root.overrideUserInterfaceStyle = theme.isLight ? .light : .dark
                let image = UIImageView(frame: root.bounds)
                image.image = UIImage(cgImage: rendered, scale: 2, orientation: .up)
                root.addSubview(image)
                #endif
                let badge = CommandBadge(identifier: "command-sticky-capture", sticky: true)
                // Include legacy-daemon contamination to exercise the native backstop too.
                badge.show("$ " + command + "\n" + String(repeating: "completion entry\n", count: 200), color: palette.textSecondary, palette: palette, in: root)
                badge.place(leading: 8, top: 2, maxWidth: size.width - 16, in: root)
                let label = try XCTUnwrap(root.subviews.last)
                XCTAssertLessThan(label.frame.height, 30)
                #if os(macOS)
                root.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let platform = "mac"
                #else
                root.layoutIfNeeded()
                let captured = UIGraphicsImageRenderer(bounds: root.bounds).image { context in root.layer.render(in: context.cgContext) }
                let png = try XCTUnwrap(captured.pngData())
                let platform = "ios"
                #endif
                try png.write(to: output.appendingPathComponent("\(platform)-\(stage)-\(theme.isLight ? "light" : "dark").png"))
            }
        }
    }
}

#if os(macOS)
private final class CommandCaptureView: NSView {
    override var isFlipped: Bool { true }
}
#endif
