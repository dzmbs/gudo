#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI
import UIKit
import XCTest
@testable import App

/// Renders Chat rows and measures the pixels: spacing in points, fades, contrast and shadows.
@MainActor
final class ChatRenderMeasureTests: XCTestCase {
    private static let width: CGFloat = 402
    private static let scale: CGFloat = 2

    func testACodeBlocksFirstLineSitsCloseUnderItsHeader() throws {
        let pixels = try Self.render(row: Self.reply("```swift\nlet clock = 2_400\n```"), theme: Self.dark)
        let clusters = Self.clusters(pixels.inkRows(columns: 0..<pixels.width / 2))
        XCTAssertGreaterThanOrEqual(clusters.count, 2, "the header and the line both draw")
        guard clusters.count >= 2 else { return }
        let gap = CGFloat(clusters[1].lowerBound - clusters[0].upperBound) / Self.scale
        XCTAssertLessThanOrEqual(gap, 12, "header to first line, in points")
    }

    func testACodeLineRunningPastTheEdgeFadesOutBeforeIt() throws {
        let theme = Self.dark
        let pixels = try Self.render(row: Self.reply("```swift\n\(String(repeating: "0", count: 80))\n```"), theme: theme)
        let line = try XCTUnwrap(Self.clusters(pixels.inkRows(columns: 0..<pixels.width / 2)).last)
        let surface = Pixels.rgb(theme.codeSurface)
        let columns = (0..<pixels.width).map { x in line.map { pixels.distance(x, $0, from: surface) }.max() ?? 0 }
        let middle = (line.lowerBound + line.upperBound) / 2
        let edge = try XCTUnwrap((0..<pixels.width).last { pixels.distance($0, middle, from: surface) <= 6 }) + 1
        let full = columns[pixels.width / 4..<pixels.width / 2].max() ?? 0
        XCTAssertGreaterThan(full, 0)
        func strongest(from: CGFloat, to: CGFloat) -> Double {
            let range = (edge - Int(from * Self.scale))..<(edge - Int(to * Self.scale))
            return Double(range.map { columns[$0] }.max() ?? 0) / Double(max(full, 1))
        }
        XCTAssertLessThanOrEqual(strongest(from: 6, to: 0), 0.3, "the glyph cut by the edge is all but gone")
        XCTAssertLessThanOrEqual(strongest(from: 14, to: 10), 0.75, "the fade starts well before the edge")
    }

    func testAPromptsTimeReadsAsStrongAsSecondaryText() throws {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let prompt = try Self.row(["User": ["text": "Run the proto tests.", "attachments": [], "queued": false]],
                                  at: now, origin: "Terminal")
        for theme in [Self.dark, Self.light] {
            let pixels = try Self.render(row: prompt, theme: theme)
            let base = pixels.rgb(1, 1)
            let inside = pixels.width - Int(30 * Self.scale)
            let bubbleTop = try XCTUnwrap((0..<pixels.height).first { pixels.distance(inside, $0, from: base) > 6 })
            let bubbleBottom = try XCTUnwrap((bubbleTop..<pixels.height).first { pixels.distance(inside, $0, from: base) <= 6 })
            let footer = bubbleBottom..<min(pixels.height, bubbleBottom + Int(30 * Self.scale))
            let time = footer.flatMap { y in (0..<inside).map { x in pixels.contrast(x, y, against: base) } }.max() ?? 0
            let reference = try Self.render(row: Self.toolGroup(), theme: theme)
            let secondary = (0..<reference.height).flatMap { y in
                (0..<reference.width).map { x in reference.contrast(x, y, against: base) }
            }.max() ?? 0
            XCTAssertGreaterThanOrEqual(time, secondary - 0.3, "\(theme.name): the words under a prompt read at text contrast")
        }
    }

    func testTheWorkingDotsCastNoShadowOnWhatIsUnderThem() throws {
        for theme in [Self.dark, Self.light] {
            let canvas = CGSize(width: 240, height: 160)
            let pixels = try Self.render(ChatWorkingIndicator().frame(width: canvas.width, height: canvas.height), theme: theme,
                                         size: canvas)
            let base = pixels.rgb(1, 1)
            let center = Int(canvas.height / 2 * Self.scale)
            let below = (center + Int(20 * Self.scale))..<(center + Int(34 * Self.scale))
            let columns = (pixels.width / 2 - Int(30 * Self.scale))..<(pixels.width / 2 + Int(30 * Self.scale))
            let darkest = below.flatMap { y in columns.map { pixels.distance($0, y, from: base) } }.max() ?? 0
            XCTAssertLessThanOrEqual(darkest, 3, "\(theme.name): under the dots reads as the background")
        }
    }

    // MARK: Rendering

    private static let dark = ThemeCatalog.theme(named: TerminalPreferences.Default.theme)
    private static let light = ThemeCatalog.theme(named: ThemePair.resolvedDefaultLight)

    private static func render(row: ChatRow, theme: TerminalTheme) throws -> Pixels {
        let size = CGSize(width: width, height: 240)
        let content = ChatRowView(row: row, isExpanded: false, toggle: {}, actions: ChatRowActions(), topSpacing: 0)
            .frame(width: size.width, height: size.height, alignment: .top)
        return try render(content, theme: theme, size: size)
    }

    private static func render(_ view: some View, theme: TerminalTheme, size: CGSize) throws -> Pixels {
        let chrome = ChromePalette(theme: theme)
        let content = view
            .background(chrome.baseColor)
            .chromeContent()
            .environment(\.terminalTheme, theme)
            .environment(\.chatRowWidth, size.width)
            .environment(\.chrome, chrome)
            .environment(\.colorScheme, chrome.scheme)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.traitOverrides.accessibilityContrast = .normal
        defer { window.isHidden = true }
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        return try Pixels(XCTUnwrap(image.cgImage))
    }

    private static func reply(_ text: String) throws -> ChatRow {
        try row(["Assistant": ["text": text, "streaming": false]])
    }

    /// Two calls folded into their summary line, "Ran 2 commands", in secondary ink.
    private static func toolGroup() throws -> ChatRow {
        let rows = try ["a", "b"].map { id in
            try row(["Tool": ["kind": "Shell", "name": "Shell", "title": "Shell", "input": "{}", "status": "Done", "output": NSNull(),
                              "diff": [], "exit": NSNull(), "duration_ms": NSNull(), "command_mark": NSNull()]], id: id)
        }
        return try XCTUnwrap(ChatToolGroups.fold(rows, expanded: []).first)
    }

    private static func row(_ body: [String: Any], id: String = "row", at: UInt64 = 0, origin: String = "Agent") throws -> ChatRow {
        let value: [String: Any] = ["id": id, "revision": 1, "turn": "turn", "parent": NSNull(), "at": at,
                                    "origin": origin, "body": body]
        let encoded = try JSONSerialization.data(withJSONObject: value)
        let item = try TimelineJSON.decode(TimelineItem.self, from: String(decoding: encoded, as: UTF8.self))
        return try XCTUnwrap(RowBuilder().rows(for: item).first)
    }

    /// Runs of rows that carry ink, separated by blank rows.
    private static func clusters(_ rows: [Bool]) -> [Range<Int>] {
        var clusters: [Range<Int>] = []
        var start: Int?
        for (index, inked) in rows.enumerated() {
            if inked, start == nil { start = index }
            if !inked, let first = start { clusters.append(first..<index); start = nil }
        }
        if let first = start { clusters.append(first..<rows.count) }
        return clusters
    }

    private struct Pixels {
        typealias RGB = (red: Int, green: Int, blue: Int)
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            self.width = width
            self.height = height
            self.bytes = bytes
        }

        static func rgb(_ color: Color) -> RGB {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return (Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }

        func rgb(_ x: Int, _ y: Int) -> RGB {
            let offset = (y * width + x) * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }

        func distance(_ x: Int, _ y: Int, from color: RGB) -> Int {
            let pixel = rgb(x, y)
            return abs(pixel.red - color.red) + abs(pixel.green - color.green) + abs(pixel.blue - color.blue)
        }

        func contrast(_ x: Int, _ y: Int, against color: RGB) -> Double {
            let first = Self.luminance(rgb(x, y)), second = Self.luminance(color)
            return (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }

        /// Rows where something draws within the given columns, against each row's own background.
        func inkRows(columns: Range<Int>) -> [Bool] {
            (0..<height).map { y in
                var counts: [Int: Int] = [:]
                for x in columns { counts[packed(rgb(x, y)), default: 0] += 1 }
                guard let background = counts.max(by: { $0.value < $1.value })?.key else { return false }
                let color = (background >> 16, (background >> 8) & 0xFF, background & 0xFF)
                return columns.contains { distance($0, y, from: color) > 90 }
            }
        }

        private func packed(_ color: RGB) -> Int { color.red << 16 | color.green << 8 | color.blue }

        private static func luminance(_ color: RGB) -> Double {
            func linear(_ channel: Int) -> Double {
                let value = Double(channel) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
    }
}
#endif
