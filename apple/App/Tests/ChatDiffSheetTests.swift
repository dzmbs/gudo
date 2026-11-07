#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI
import UIKit
import XCTest
@testable import App

@MainActor
final class ChatDiffSheetTests: XCTestCase {
    func testRepeatedFileSnapshotsRenderAsIndependentNativeReadOnlyRows() async throws {
        let file = try sample()
        let groups = [ChatToolDiff(item: "first", files: [file]), ChatToolDiff(item: "second", files: [file])]
        let window = try show(groups)
        defer { close(window) }
        try await wait { (self.collection(in: window)?.numberOfItems(inSection: 0) ?? 0) > 5 }
        try await Task.sleep(for: .milliseconds(180))
        let collection = try XCTUnwrap(collection(in: window))
        XCTAssertGreaterThan(collection.contentSize.height, 0)
        XCTAssertLessThanOrEqual(collection.visibleCells.count, 20)
        let snapshots = try ChatDiffSnapshot(groups: groups)
        XCTAssertNotEqual(snapshots.files[0].id, snapshots.files[1].id)
        try capture(window)
    }

    func testAnEmptyScopedSelectionDoesNotCreateRowsFromAnotherTurn() async throws {
        let window = try show([])
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(collection(in: window))
    }

    private func sample() throws -> TimelineFileDiff {
        let lines = [["kind": "Context", "text": "func value() {"],
                     ["kind": "Removed", "text": "    return previous"],
                     ["kind": "Added", "text": "    return current"],
                     ["kind": "Context", "text": "}"]]
        let hunk: [String: Any] = ["old_start": 10, "old_lines": 3, "new_start": 10, "new_lines": 3,
                                    "header": "", "lines": lines]
        let json = try TimelineFixtureJSON.json([
            "path": "Sources/sample.swift", "change": "Modified", "binary": false,
            "additions": 1, "deletions": 1, "hunks": [hunk], "hunks_omitted": true
        ])
        return try TimelineJSON.decode(TimelineFileDiff.self, from: json)
    }

    private func show(_ groups: [ChatToolDiff]) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ThemedRoot {
            ChatDiffSheet(groups: groups, openTerminal: {})
        })
        window.isHidden = false
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func collection(in view: UIView) -> UICollectionView? {
        if let collection = view as? UICollectionView { return collection }
        return view.subviews.lazy.compactMap { self.collection(in: $0) }.first
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Chat diff did not reach its expected native state")
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
        try image.pngData()?.write(to: root.appendingPathComponent("\(device)-chat-diff-preview.png"))
    }
}
#endif
