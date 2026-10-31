#if os(macOS)
import AppKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Browsing in a Files leaf stays in the leaf: folders and files open there with a way back,
/// folders expand in place, and the terminal beside it stays. Clicks go through the window as a
/// user's do.
@MainActor
final class FilesLeafNavigationTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var model: WindowModel!
    private var window: NSWindow!
    private var navigator: FilesNavigator!
    /// The tab this test opened: closed again, so the shared local workspace is left as found.
    private var openedTab: (workspace: Workspace, tab: TabId)?
    private let root = MockFileSource().root

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_UNNAMED_MOCK=1)")
        model = WindowModel(app: .shared)
        model.start()
        let frame = NSRect(x: -30000, y: -30000, width: 1180, height: 760)
        window = OffscreenWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { await pump(0.1) }
        let workspace = try XCTUnwrap(model.workspace)
        // A tab of its own: the local workspace is shared by every test in the process.
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        openedTab = workspace.session.tabs.first { !before.contains($0.id) }.map { (workspace, $0.id) }
        for _ in 0..<20 where workspace.focusedPane == nil { await pump(0.1) }
        let member = model.openToolLeaf(.files)
        await pump(1.5)
        navigator = try XCTUnwrap(model.filesNavigators[member.id], "the leaf browses in place")
    }

    override func tearDown() async throws {
        guard let model else { return }
        for tab in model.composites.tabs { model.closeMixedTab(tab.id) }
        if let openedTab { openedTab.workspace.apply(.closeTab(openedTab.tab)) }
        await pump(0.5)
        window?.close()
        model.close()
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
        let view = view ?? window.contentView!
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The leaf's list: the window's right half (the sidebar and terminal are on the left).
    private func list(file: StaticString = #filePath, line: UInt = #line) throws -> NSTableView {
        return try XCTUnwrap(views(NSTableView.self).first { $0.convert($0.bounds, to: nil).minX > 600 }, "the list is in the leaf", file: file, line: line)
    }

    /// Row of `name` in a mock listing, folders first as the browser sorts.
    private func index(of name: String) async throws -> Int {
        let entries = try await MockFileSource().list(root).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return try XCTUnwrap(entries.firstIndex { $0.name == name })
    }

    private func click(row: Int, x: CGFloat? = nil) async throws {
        let table = try list()
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: x.map { rect.minX + $0 } ?? rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        await pump(1)
    }

    private func key(_ characters: String) async {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: 0)!
        _ = window.performKeyEquivalent(with: event)
        await pump(1)
    }

    private func assertStillBeside(file: StaticString = #filePath, line: UInt = #line) throws {
        _ = try list(file: file, line: line)
        XCTAssertFalse(views(NSView.self).filter { String(describing: type(of: $0)) == "TerminalView" }.isEmpty, "the terminal is still there", file: file, line: line)
        XCTAssertEqual(model.activeMixed?.tools.count, 1, "the Files leaf is still in the tab", file: file, line: line)
    }

    func testFoldersOpenInTheLeafWithAWayBack() async throws {
        try await click(row: index(of: "apple"))
        XCTAssertEqual(navigator.place, .folder("\(root)/apple"))
        try assertStillBeside()

        try await click(row: index(of: "crates"))
        XCTAssertEqual(navigator.place, .folder("\(root)/apple/crates"), "two levels down")
        try assertStillBeside()

        await key("[")
        XCTAssertEqual(navigator.place, .folder("\(root)/apple"), "⌘[ goes back")
        await key("]")
        XCTAssertEqual(navigator.place, .folder("\(root)/apple/crates"), "⌘] forward")
        await key(String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertEqual(navigator.place, .folder("\(root)/apple"), "⌘↑ the enclosing folder")
        try assertStillBeside()
        XCTAssertEqual(navigator.trail, ["~", "~/projects", root, "\(root)/apple"], "the path bar's folders")
        navigator.go(to: "~/projects")
        XCTAssertEqual(navigator.place, .folder("~/projects"), "a folder in the path bar is a click away")
    }

    func testFilesPreviewInTheLeaf() async throws {
        try await click(row: index(of: "Cargo.toml"))
        guard case .file(let entry) = navigator.place else { return XCTFail("the preview opens: \(navigator.place)") }
        XCTAssertEqual(entry.name, "Cargo.toml")
        XCTAssertTrue(views(NSView.self).contains { String(describing: type(of: $0)) == "TerminalView" }, "the terminal is still there")
        await key("[")
        XCTAssertEqual(navigator.place, .folder(root), "back to the folder")
        try assertStillBeside()
    }

    func testFoldersExpandInPlace() async throws {
        let rows = try list().numberOfRows
        try await click(row: index(of: "apple"), x: 14)
        XCTAssertEqual(navigator.place, .folder(root), "expanding stays on the level")
        XCTAssertTrue(navigator.expanded.contains("\(root)/apple"))
        XCTAssertEqual(try list().numberOfRows, rows * 2, "the folder's entries show beneath it")
        try await click(row: index(of: "apple"), x: 14)
        XCTAssertEqual(try list().numberOfRows, rows, "and fold away")
    }
}
#endif
