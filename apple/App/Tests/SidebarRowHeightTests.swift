import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import App

/// The native list sets a row's new height at once when its content grows or shrinks (a tab gains
/// or loses its second line), so the content lands with it: the title never slides inside a row
/// that already moved, and a line that leaves is never left half drawn at the row's new edge.
@MainActor
final class SidebarRowHeightTests: XCTestCase {
    #if os(macOS)
    func testARowGainingOrLosingItsSubtitleLandsWithItsHeight() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        MockPaneStatus.fixture = [:]
        let model = WindowModel(app: .shared)
        model.start()
        defer {
            MockPaneStatus.fixture = nil
            model.close()
        }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let workspace = try XCTUnwrap(model.workspace)
        for tab in workspace.session.tabs { workspace.apply(.closeTab(tab.id)) }
        workspace.apply(.newTab)
        for _ in 0..<20 where workspace.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        let pane = try XCTUnwrap(workspace.focusedPane)
        workspace.apply(.newTab)
        let first = try XCTUnwrap(workspace.session.tabs.first)
        workspace.selectTab(first.id)
        for _ in 0..<50 where workspace.context(of: first) != "~" { try await Task.sleep(for: .milliseconds(100)) }
        model.isSidebarShown = true

        let sidebar = try await SidebarWindow(model: model)
        defer { sidebar.close() }
        let tabRow = sidebar.table.numberOfRows - 2
        let oneLine = sidebar.table.rect(ofRow: tabRow).height

        let beforeGrowing = try sidebar.picture(ofRow: tabRow, upperHalfOnly: true)
        workspace.canvasTitles[pane] = "Sketch"
        let growing = try await sidebar.framesOfText(inRow: tabRow, upperHalfOnly: true)
        XCTAssertGreaterThan(sidebar.table.rect(ofRow: tabRow).height, oneLine + 4, "the row grows for its subtitle")
        XCTAssertEqual(sidebar.table.rect(ofRow: tabRow + 1).minY, sidebar.table.rect(ofRow: tabRow).maxY, accuracy: 0.5,
                       "the next row starts below it")
        sidebar.assertSettled(growing, from: beforeGrowing, "the title stays put while the subtitle fades in")

        let beforeShrinking = try sidebar.picture(ofRow: tabRow, upperHalfOnly: false)
        workspace.canvasTitles[pane] = nil
        let shrinking = try await sidebar.framesOfText(inRow: tabRow, upperHalfOnly: false)
        XCTAssertEqual(sidebar.table.rect(ofRow: tabRow).height, oneLine, accuracy: 0.5, "and shrinks back when it goes")
        sidebar.assertSettled(shrinking, from: beforeShrinking, "the subtitle leaves with the row's height")
    }

    /// The real sidebar in a window, drawn the way the screen shows it.
    @MainActor
    private struct SidebarWindow {
        let window: NSWindow
        let table: NSTableView

        init(model: WindowModel) async throws {
            let host = NSHostingView(rootView: WorkspaceSidebar().environment(model).environment(model.app))
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            var found: NSTableView?
            for _ in 0..<40 where found == nil {
                host.layoutSubtreeIfNeeded()
                found = Self.table(in: host)
                if found == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
            table = try XCTUnwrap(found, "the sidebar is a native table")
            try await Task.sleep(for: .milliseconds(500))
        }

        func close() {
            window.contentView = nil
            window.close()
        }

        /// The words of `row` (its title and subtitle, right of the program icon, which crossfades
        /// on its own) drawn every few milliseconds through a change's motion, then once at rest.
        func framesOfText(inRow row: Int, upperHalfOnly: Bool) async throws -> [Data] {
            var frames: [Data] = []
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(15))
                frames.append(try picture(ofRow: row, upperHalfOnly: upperHalfOnly))
            }
            try await Task.sleep(for: .milliseconds(800))
            frames.append(try picture(ofRow: row, upperHalfOnly: upperHalfOnly))
            return frames
        }

        /// Every frame shows the row as it was or as it ends: nothing in between.
        func assertSettled(_ frames: [Data], from before: Data, _ message: String, line: UInt = #line) {
            guard let rest = frames.last else { return XCTFail("no frames", line: line) }
            let unsettled = frames.dropLast().filter { $0 != rest && $0 != before }.count
            XCTAssertEqual(unsettled, 0, "\(message): \(unsettled) of \(frames.count - 1) frames differ from rest", line: line)
        }

        func picture(ofRow row: Int, upperHalfOnly: Bool) throws -> Data {
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var rect = table.convert(table.rect(ofRow: row), to: view)
            let textLeading = DS.Space.s + DS.Space.m + DS.Space.xs + SidebarFont.icon + DS.Space.gap10 - 1
            rect = CGRect(x: rect.minX + textLeading, y: rect.minY, width: rect.width - textLeading, height: rect.height)
            if upperHalfOnly {
                rect.size.height /= 2
                if !view.isFlipped { rect.origin.y += rect.height }
            }
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
            let pixels = CGRect(x: rect.minX * scale, y: top * scale, width: rect.width * scale, height: rect.height * scale).integral
            let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: pixels))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: image).tiffRepresentation)
        }

        private static func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for subview in view.subviews {
                if let found = table(in: subview) { return found }
            }
            return nil
        }
    }
    #endif
}
