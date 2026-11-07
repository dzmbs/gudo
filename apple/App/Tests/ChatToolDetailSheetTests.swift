#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI
import UIKit
import XCTest
@testable import App

@MainActor
final class ChatToolDetailSheetTests: XCTestCase {
    func testTheNativeSheetFetchesRecordedOutputInsteadOfOnlyDisplayingItsPreview() async throws {
        let full = (0..<60).map { "Output line \($0): this is not in the preview." }.joined(separator: "\n")
        var requests: [(UInt64, UInt32)] = []
        let tool = try tool(output: true)
        let window = try show(tool: tool) { offset, length in
            requests.append((offset, length))
            return try TimelineFixtureJSON.json(["text": full, "total_bytes": full.utf8.count,
                                                  "next_offset": NSNull()])
        }
        defer { close(window) }
        try await wait { requests.count == 1 && self.hasScrollView(window) }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(requests.first?.0, 0)
        XCTAssertEqual(requests.first?.1, ChatOutputLimits.pageBytes)
        XCTAssertNotNil(control(in: window))
        try capture(window)
    }

    func testAToolWithoutRecordedOutputDoesNotAttemptARead() async throws {
        var requests = 0
        let window = try show(tool: tool(output: false)) { _, _ in
            requests += 1
            throw ChatOutputError.invalidPage
        }
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(requests, 0)
        let picker = try XCTUnwrap(control(in: window))
        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        try await wait { self.hasScrollView(window) }
        XCTAssertEqual(requests, 0)
    }

    private func tool(output: Bool) throws -> TimelineTool {
        var value: [String: Any] = ["kind": "Shell", "name": "Bash", "title": "Recorded tool output",
                                     "input": "printf 'private fixture'", "status": "Done", "diff": []]
        if output { value["output"] = ["handle": "1:2:fixture", "preview": "Preview only", "bytes": 10_000] }
        return try TimelineJSON.decode(TimelineTool.self, from: TimelineFixtureJSON.json(value))
    }

    private func show(tool: TimelineTool, source: @escaping ChatOutputReader.Source) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ThemedRoot {
            ChatToolDetailSheet(tool: tool, source: source, openTerminal: {})
        })
        window.isHidden = false
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func control(in view: UIView) -> UISegmentedControl? {
        if let picker = view as? UISegmentedControl { return picker }
        return view.subviews.lazy.compactMap { self.control(in: $0) }.first
    }

    private func hasScrollView(_ view: UIView) -> Bool {
        view is UIScrollView || view.subviews.contains { self.hasScrollView($0) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Tool detail did not reach its expected native state")
        throw CancellationError()
    }

    private func capture(_ window: UIWindow) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try image.pngData()?.write(to: root.appendingPathComponent("\(device)-tool-output.png"))
    }
}
#endif
