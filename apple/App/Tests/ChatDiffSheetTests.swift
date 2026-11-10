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

    func testResizingKeepsTheRenderedDiffUntilTheNewLayoutIsReady() async throws {
        let window = try show([ChatToolDiff(item: "tool", files: [try sample()])])
        defer { close(window) }
        try await wait { (self.collection(in: window)?.numberOfItems(inSection: 0) ?? 0) > 5 }
        for width in [window.bounds.width * 0.7, window.bounds.width / 0.7] {
            window.frame.size.width = width
            window.layoutIfNeeded()
            for _ in 0..<100 {
                XCTAssertNotNil(collection(in: window), "The diff went blank while resizing")
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    func testAnEmptyScopedSelectionDoesNotCreateRowsFromAnotherTurn() async throws {
        let window = try show([])
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(collection(in: window))
    }

    func testRecordedResultsReplaceNativePreviewRowsWithoutClaimingACompleteTurn() async throws {
        var file = try sample()
        let group = ChatToolDiff(item: "tool", files: [file], resultHandle: "7:19:tool")
        file.hunksOmitted = false
        file.additions = 100
        file.deletions = 0
        file.hunks[0].oldLines = 0
        file.hunks[0].newLines = 100
        file.hunks[0].lines = Array(repeating: file.hunks[0].lines[2], count: 100)
        let json = String(decoding: try JSONEncoder().encode([file]), as: UTF8.self)
        for scheme in [ColorScheme.dark, .light] {
            var handles: [String] = []
            let reader = ChatDiffReader(groups: [group]) { handle in handles.append(handle); return json }
            let window = try show([group], reader: reader, scheme: scheme)
            defer { close(window) }
            try await wait { (self.collection(in: window)?.numberOfItems(inSection: 0) ?? 0) > 5 }
            try await Task.sleep(for: .milliseconds(180))
            try capture(window, suffix: "fetch-\(scheme)")
            XCTAssertTrue(handles.isEmpty)
            reader.requestRecorded()
            try await wait { self.collection(in: window)?.numberOfItems(inSection: 0) == 103 }
            XCTAssertEqual(handles, ["7:19:tool"])
            XCTAssertTrue(reader.isRecorded)
            XCTAssertNil(reader.error)
            let collection = try XCTUnwrap(collection(in: window))
            let line = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 102, section: 0)))
            XCTAssertGreaterThan(line.frame.height, 0)
            XCTAssertLessThanOrEqual(collection.visibleCells.count, Int(ceil(collection.bounds.height / line.frame.height)) + 4)
            try await Task.sleep(for: .milliseconds(180))
            try capture(window, suffix: "recorded-\(scheme)")
        }
    }

    func testFailedRecordedReadsKeepTheNativePreviewAndAVisibleTerminalFallback() async throws {
        let group = ChatToolDiff(item: "tool", files: [try sample()], resultHandle: "7:19:tool")
        let reader = ChatDiffReader(groups: [group]) { _ in throw ChatDiffError.tooLarge }
        let window = try show([group], reader: reader)
        defer { close(window) }
        try await wait { (self.collection(in: window)?.numberOfItems(inSection: 0) ?? 0) > 5 }
        let count = try XCTUnwrap(collection(in: window)).numberOfItems(inSection: 0)
        await reader.loadRecorded()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(collection(in: window)?.numberOfItems(inSection: 0), count)
        XCTAssertEqual(reader.error, ChatDiffError.tooLarge.errorDescription)
        XCTAssertFalse(reader.isRecorded)
        XCTAssertTrue(reader.canLoadRecorded)
        try capture(window, suffix: "recorded-error")
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

    private func show(_ groups: [ChatToolDiff], reader: ChatDiffReader? = nil,
                      scheme: ColorScheme = .dark) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let theme = ThemeCatalog.theme(named: scheme == .dark ? "Dracula" : "Apple System Colors Light")
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = UIHostingController(rootView:
            ChatDiffSheet(reader: reader ?? ChatDiffReader(groups: groups), openTerminal: {})
                .environment(\.terminalTheme, theme).environment(\.chrome, ChromePalette(theme: theme, scheme: scheme))
                .environment(\.colorScheme, scheme).preferredColorScheme(scheme))
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

    private func capture(_ window: UIWindow, suffix: String = "preview") throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try image.pngData()?.write(to: root.appendingPathComponent("\(device)-chat-diff-\(suffix).png"))
    }
}
#endif
