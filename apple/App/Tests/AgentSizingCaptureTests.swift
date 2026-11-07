import ImageIO
import TerminalCore
import TerminalRenderer
import UniformTypeIdentifiers
import XCTest

@MainActor
final class AgentSizingCaptureTests: XCTestCase {
    func testRealAgentSnapshotsFitBothNativeViewportsWithoutReflow() throws {
        guard let directory = ProcessInfo.processInfo.environment["GUDO_AGENT_SIZING_CAPTURE_DIR"] else {
            throw XCTSkip("Run AGENT_TUI_MIRROR=1 scripts/agent-tui-parity.sh first; needs private real-agent snapshots")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "snapshot" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 10)
        let output = root.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        #if os(macOS)
        let platform = "mac"
        #else
        let platform = "ios"
        #endif
        for file in files {
            let snapshot = try Data(contentsOf: file)
            let parts = try XCTUnwrap(Terminal.splitSnapshot(snapshot))
            for (viewport, size) in [("desktop", CGSize(width: 900, height: 650)), ("phone", CGSize(width: 300, height: 600))] {
                let terminal = Terminal(cols: 80, rows: 24) { _ in }
                try terminal.restore(snapshot: parts.ready)
                let actual = terminal.size
                let isPhoneGrid = file.lastPathComponent.contains("phone")
                XCTAssertEqual(actual.cols, isPhoneGrid ? 45 : file.lastPathComponent.contains("returned") ? 219 : 160)
                XCTAssertEqual(actual.rows, isPhoneGrid ? 20 : 40)
                let surface = try TerminalSurface(terminal: terminal, fontSize: 13)
                surface.sizeFollowsStream = true
                var requests = 0
                surface.onGridChange = { _ in requests += 1 }
                surface.layout(size: size, scale: 2)
                let wanted = surface.grid
                let first = surface.rect(for: GridPoint(x: 0, y: 0))
                let last = surface.rect(for: GridPoint(x: Int(actual.cols) - 1, y: Int(actual.rows) - 1))
                XCTAssertGreaterThanOrEqual(first.minX, 0)
                XCTAssertGreaterThanOrEqual(first.minY, 0)
                XCTAssertLessThanOrEqual(last.maxX, size.width + 0.01)
                XCTAssertLessThanOrEqual(last.maxY, size.height + 0.01)
                XCTAssertEqual(first.minX, size.width - last.maxX, accuracy: 0.01)
                XCTAssertEqual(first.minY, size.height - last.maxY, accuracy: 0.01)
                surface.outputArrived()
                XCTAssertTrue(surface.renderIfDirty(offscreen: true))
                XCTAssertEqual(surface.grid, wanted)
                XCTAssertEqual(terminal.size.cols, actual.cols)
                XCTAssertEqual(terminal.size.rows, actual.rows)
                XCTAssertEqual(requests, 1)
                let image = try XCTUnwrap(surface.snapshot())
                let name = "\(platform)-\(file.deletingPathExtension().lastPathComponent)-\(viewport).png"
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
        }
    }
}
