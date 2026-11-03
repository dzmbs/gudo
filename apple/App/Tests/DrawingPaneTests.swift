import DesignSystem
import HostKit
import PaneLayout
import WebKit
import XCTest
@testable import App
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A drawing pane is named after its file wherever panes are listed, and takes the keyboard from
/// the terminal behind it, so the software keyboard and key bar go away.
@MainActor
final class DrawingPaneTests: XCTestCase {
    private final class Quiet: PaneBackend, @unchecked Sendable {
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
    }

    private var workspace: Workspace!

    /// A terminal and, beside it, the pane a drawing will cover (focused, as New Drawing leaves it).
    private func make() -> (terminal: PaneId, drawing: PaneId) {
        var session = Session()
        let terminal = session.activeTab!.focused
        session.apply(.split(terminal, .horizontal))
        let drawing = session.activeTab!.focused
        workspace = Workspace(layout: LocalLayoutStore(session: session)) { _ in Quiet() }
        return (terminal, drawing)
    }

    override func tearDown() {
        workspace?.close()
        super.tearDown()
    }

    func testADrawingIsCalledByItsFileNameWithoutTheExtension() {
        XCTAssertEqual(DrawingFile.title(ofPath: "/src/app/drawing-2026-11-03-2306.excalidraw"), "drawing-2026-11-03-2306")
        XCTAssertEqual(DrawingFile.title(ofPath: "/src/app/login flow.excalidraw"), "login flow")
    }

    func testTheHeaderListsAndWindowTitleNameTheDrawing() throws {
        let (terminal, drawing) = make()
        workspace.canvasTitles[drawing] = DrawingFile.title(ofPath: "/src/drawing-2026-11-03-2306.excalidraw")

        XCTAssertEqual(workspace.programName(of: drawing), "drawing-2026-11-03-2306")
        let identity = workspace.programIdentity(of: drawing)
        XCTAssertEqual(identity.displayName, "drawing-2026-11-03-2306", "pane switchers and the pane header")
        XCTAssertEqual(identity.symbol, "scribble.variable")
        XCTAssertFalse(identity.isShell)
        let tab = try XCTUnwrap(workspace.session.activeTab)
        XCTAssertEqual(workspace.context(of: tab), "drawing-2026-11-03-2306", "the tab row, the window subtitle and ⌘K")

        workspace.apply(.focus(terminal))
        let refocused = try XCTUnwrap(workspace.session.activeTab)
        XCTAssertNotEqual(workspace.context(of: refocused), "drawing-2026-11-03-2306", "the terminal says its own")
        XCTAssertTrue(workspace.programIdentity(of: terminal).isShell)
    }

    func testARenameRenamesItEverywhereAtOnce() {
        let (_, drawing) = make()
        workspace.canvasTitles[drawing] = DrawingFile.untitled
        XCTAssertEqual(workspace.programName(of: drawing), "Drawing")
        let redrawn = Flag()
        withObservationTracking { _ = workspace.programIdentity(of: drawing) } onChange: { redrawn.set() }
        workspace.canvasTitles[drawing] = DrawingFile.title(ofPath: "/src/sketches/login.excalidraw")
        XCTAssertTrue(redrawn.value, "views showing the pane redraw")
        XCTAssertEqual(workspace.programIdentity(of: drawing).displayName, "login")
    }

    private final class Flag: @unchecked Sendable {
        private(set) var value = false
        func set() { value = true }
    }

    func testClosingTheDrawingPaneForgetsItsName() {
        let (_, drawing) = make()
        workspace.canvasTitles[drawing] = "login"
        workspace.apply(.close(drawing))
        XCTAssertNil(workspace.canvasTitles[drawing])
    }

    func testAPlainTerminalHasNoCanvasToTakeItsKeyboard() throws {
        let (terminal, _) = make()
        XCTAssertNil(PaneDrawing.canvas(in: try XCTUnwrap(workspace.pane(terminal))))
    }

    // MARK: Keyboard

    /// The terminal typed into gives up the keyboard to the page, so its software keyboard and key
    /// bar go away while keys still have a responder; tapping back gives it the keyboard again.
    func testThePageTakesTheKeyboardFromTheTerminalAndGivesItBack() async throws {
        let (terminal, _) = make()
        let terminalView = try XCTUnwrap(workspace.pane(terminal)?.view)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let root = try XCTUnwrap(window.rootViewController?.view)
        terminalView.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        root.addSubview(terminalView)
        root.addSubview(page)
        XCTAssertTrue(terminalView.becomeFirstResponder())
        func terminalHasKeyboard() -> Bool { terminalView.isFirstResponder }
        #else
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let root = try XCTUnwrap(window.contentView)
        terminalView.frame = CGRect(x: 300, y: 0, width: 300, height: 300)
        root.addSubview(terminalView)
        root.addSubview(page)
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        func terminalHasKeyboard() -> Bool { window.firstResponder === terminalView }
        #endif
        XCTAssertFalse(page.ownsKeyboard)

        page.claimKeyboard()
        for _ in 0..<50 where !page.ownsKeyboard { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(page.ownsKeyboard, "keys and shortcuts reach the page")
        XCTAssertFalse(terminalHasKeyboard(), "the terminal's keyboard and key bar go away")

        #if canImport(UIKit)
        XCTAssertTrue(terminalView.becomeFirstResponder())
        #else
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        #endif
        XCTAssertTrue(terminalHasKeyboard())
        XCTAssertFalse(page.ownsKeyboard)

        terminalView.removeFromSuperview()
        page.removeFromSuperview()
        #if canImport(UIKit)
        window.isHidden = true
        #else
        window.close()
        #endif
    }
}
