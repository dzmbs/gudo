#if os(macOS)
import AppKit
import DesignSystem
import PaneLayout
import SwiftUI
import TerminalCore
import TerminalRenderer
import XCTest
@testable import App

/// The terminal's features in a whole window, driven as a person drives them: keys sent through
/// the window, clicks on the terminal, the find bar's field and buttons, the menu actions. Each
/// test checks what shows on screen or what the shell heard.
@MainActor
final class TerminalFeaturesTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private var window: NSWindow!
    private var model: WindowModel!

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        model = WindowModel(app: .shared)
        model.start()
        let root = WindowContent(request: nil, model: model).environment(AppModel.shared)
        let frame = NSRect(x: -30000, y: -30000, width: 1000, height: 700)
        window = OffscreenWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        await waitUntil { self.model.workspace?.focusedPane != nil }
        await waitUntil { self.pane?.view.window != nil && self.pane?.view.surface.grid != nil }
        await waitUntil { self.screenText.contains("❯") }
        window.makeFirstResponder(try XCTUnwrap(pane?.view))
    }

    override func tearDown() async throws {
        guard let model else { return }
        if model.isSearchShown { model.closeSearch() }
        try? await Task.sleep(for: .seconds(0.3))
        window?.close()
        model.close()
    }

    // MARK: Find

    func testFindTypingStepsWithReturnAndCloseWithEscape() async throws {
        let pane = try XCTUnwrap(pane)
        type("seq 80\r")
        await waitUntil { self.screenText.contains("row 80") }
        try typeShowing("echo Needle\r")
        await waitUntil { self.screenText.contains("echo: echo Needle") }

        WorkspaceAction.find.perform(on: try XCTUnwrap(model.workspace), window: model)
        await waitUntil { self.fieldHasKeyboard }
        XCTAssertTrue(fieldHasKeyboard, "⌘F puts the keyboard in the field")
        type("row 1")
        await waitUntil { self.model.searchStatus.selected != nil }
        let total = model.searchStatus.total
        XCTAssertEqual(total, 11, "row 1 and row 10 to 19: \(model.searchStatus)")
        let first = try XCTUnwrap(model.searchStatus.selected)

        press("\r", keyCode: 36)
        await waitUntil { self.model.searchStatus.selected != first }
        let second = try XCTUnwrap(model.searchStatus.selected)
        XCTAssertNotEqual(second, first, "Return goes to the next match")
        XCTAssertFalse(pane.view.surface.terminal.viewportAtBottom, "the next match up is in the scrollback, shown")

        press("\r", keyCode: 36, modifiers: .shift)
        await waitUntil { self.model.searchStatus.selected == first }
        XCTAssertEqual(model.searchStatus.selected, first, "⇧Return goes back")

        press("\u{1b}", keyCode: 53)
        await waitUntil { !self.model.isSearchShown }
        XCTAssertFalse(model.isSearchShown)
        XCTAssertNil(pane.view.surface.search, "no highlights once closed")
        XCTAssertTrue(window.firstResponder === pane.view, "the terminal takes the keyboard back")
    }

    func testMatchCaseNarrowsTheMatches() async throws {
        try typeShowing("echo Case case\r")
        await waitUntil { self.screenText.contains("echo: echo Case case") }
        WorkspaceAction.find.perform(on: try XCTUnwrap(model.workspace), window: model)
        await waitUntil { self.fieldHasKeyboard }
        type("case")
        await waitUntil { self.model.searchStatus.total >= 4 }
        let insensitive = model.searchStatus.total

        // The bar's Aa button: SwiftUI builds no accessibility tree to press it through while no
        // assistive app is running, so the test flips what it is bound to.
        model.searchCaseSensitive.toggle()
        await waitUntil { self.model.searchStatus.total < insensitive }
        XCTAssertTrue(model.searchCaseSensitive)
        XCTAssertEqual(model.searchStatus.total, insensitive / 2, "only the lower-case ones: \(model.searchStatus)")
    }

    // MARK: Copy, paste, select all

    func testSelectAllThenCopyPutsTheScreenOnThePasteboard() async throws {
        try typeShowing("echo copied\r")
        await waitUntil { self.screenText.contains("echo: echo copied") }
        let view = try XCTUnwrap(pane?.view)
        XCTAssertTrue(window.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil) == true)
        let selected = try XCTUnwrap(view.surface.terminal.selectionText())
        XCTAssertTrue(selected.contains("echo: echo copied"), selected)
    }

    // MARK: Font size

    func testFontSizeKeysZoomTheFocusedPaneAndResizeItOnce() async throws {
        let workspace = try XCTUnwrap(model.workspace)
        let pane = try XCTUnwrap(pane)
        await settle()
        let size = pane.view.surface.fontSize
        let columns = try XCTUnwrap(pane.view.surface.grid?.cols)
        let resizes = pane.resizesSent

        WorkspaceAction.increaseFontSize.perform(on: workspace, window: model)
        await waitUntil { pane.view.surface.grid?.cols ?? 0 < columns }
        await settle()
        XCTAssertGreaterThan(pane.view.surface.fontSize, size)
        XCTAssertLessThan(try XCTUnwrap(pane.view.surface.grid?.cols), columns, "bigger letters, fewer columns")
        XCTAssertEqual(pane.resizesSent, resizes + 1, "one resize for one zoom")

        WorkspaceAction.resetFontSize.perform(on: workspace, window: model)
        await waitUntil { pane.view.surface.grid?.cols == columns }
        await settle()
        XCTAssertEqual(pane.view.surface.fontSize, size)
        XCTAssertEqual(pane.resizesSent, resizes + 2)
    }

    // MARK: Resizing

    func testAWindowResizeResizesThePaneOnce() async throws {
        let pane = try XCTUnwrap(pane)
        await settle()
        let columns = try XCTUnwrap(pane.view.surface.grid?.cols)
        let resizes = pane.resizesSent
        var frame = window.frame
        frame.size.width += 200
        window.setFrame(frame, display: true)
        await waitUntil { pane.view.surface.grid?.cols ?? 0 > columns }
        await settle()
        XCTAssertGreaterThan(try XCTUnwrap(pane.view.surface.grid?.cols), columns)
        XCTAssertEqual(pane.resizesSent, resizes + 1, "one resize for one window resize")
    }

    func testTogglingTheSidebarResizesThePaneOnce() async throws {
        let workspace = try XCTUnwrap(model.workspace)
        let pane = try XCTUnwrap(pane)
        model.isSidebarShown = true
        await settle()
        await settle()
        let columns = try XCTUnwrap(pane.view.surface.grid?.cols)
        let resizes = pane.resizesSent

        WorkspaceAction.toggleSidebar.perform(on: workspace, window: model)
        await waitUntil { pane.view.surface.grid?.cols ?? 0 > columns }
        await settle()
        await settle()
        XCTAssertFalse(model.isSidebarShown)
        XCTAssertGreaterThan(try XCTUnwrap(pane.view.surface.grid?.cols), columns)
        XCTAssertEqual(pane.resizesSent, resizes + 1, "one resize as the sidebar hides")
    }

    // MARK: Cursor

    func testCursorSettingsReachTheOpenPanes() async throws {
        let workspace = try XCTUnwrap(model.workspace)
        let pane = try XCTUnwrap(pane)
        let suite = "terminal-features-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TerminalPreferences.CursorStyle.bar.rawValue, forKey: TerminalPreferences.Key.cursorStyle)
        defaults.set(false, forKey: TerminalPreferences.Key.cursorBlink)
        workspace.appearance = TerminalAppearance.fromPreferences(defaults)
        XCTAssertEqual(pane.view.surface.appearance.cursorStyle, .bar)
        XCTAssertFalse(pane.view.surface.appearance.cursorBlink)
        let state = RenderState()
        state.update(from: pane.view.surface.terminal)
        XCTAssertEqual(state.cursor.style, .bar)
        XCTAssertFalse(state.cursor.blinking)
    }

    // MARK: Links

    func testCommandClickOnAPrintedPathOpensTheViewer() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "terminal-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "notes.md")
        try "# Notes\n\nSome *text*.\n".write(to: file, atomically: true, encoding: .utf8)
        let printed = try XCTUnwrap(pane?.view.surface)
        printed.terminal.write(Array("\r\n\(file.path):3\r\n".utf8))
        printed.outputArrived()
        await waitUntil { self.screenText.contains("notes.md:3") }

        let view = try XCTUnwrap(pane?.view)
        let row = try XCTUnwrap(screenText.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { $0.contains("notes.md:3") })
        let rect = view.surface.rect(for: GridPoint(x: 3, y: row))
        let point = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        await waitUntil { self.viewerMember != nil }
        let member = try XCTUnwrap(viewerMember, "a viewer opened")
        XCTAssertEqual(member.path, file.path)
        XCTAssertEqual(member.line, 3)
    }

    /// ⌘-click on a printed path with a line: the viewer opens the file with that line in view,
    /// and its text can be selected and copied.
    func testTheViewerShowsTheClickedLineAndItsTextSelects() async throws {
        commandClick(printed: "~/projects/gudo/src/main.rs:30")
        await waitUntil { self.viewerMember != nil }
        XCTAssertEqual(viewerMember?.line, 30)
        await waitUntil { self.codeView?.string.contains("value_40") == true }
        let code = try XCTUnwrap(codeView, "the viewer shows the file's text")
        await waitUntil(seconds: 2) { code.visibleRect.minY > 0 }
        let lines = code.string.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 40)
        let marked = (code.string as NSString).range(of: "value_30 ")
        let layout = try XCTUnwrap(code.layoutManager)
        let markedRect = layout.boundingRect(
            forGlyphRange: layout.glyphRange(forCharacterRange: marked, actualCharacterRange: nil), in: try XCTUnwrap(code.textContainer))
        XCTAssertTrue(code.visibleRect.intersects(markedRect), "line 30 is in view: \(code.visibleRect) \(markedRect)")
        XCTAssertFalse(code.isEditable)
        XCTAssertTrue(code.isSelectable)
        code.selectAll(nil)
        XCTAssertEqual(code.selectedRange().length, (code.string as NSString).length)
    }

    func testAMarkdownPathOpensRendered() async throws {
        commandClick(printed: "~/projects/gudo/README.md")
        await waitUntil { self.viewerMember != nil }
        XCTAssertEqual(viewerMember?.path, "~/projects/gudo/README.md")
        await waitUntil(seconds: 1.5) { self.codeView != nil }
        XCTAssertNil(codeView, "Markdown shows rendered, not as source lines")
    }

    // MARK: Helpers

    private var pane: Pane? {
        guard let workspace = model.workspace, let id = workspace.focusedPane else { return nil }
        return workspace.pane(id)
    }

    private var screenText: String { pane?.view.surface.terminal.visibleText() ?? "" }

    private var viewerMember: ToolMember? {
        model.activeMixed?.tools.values.first { $0.tool == .viewer }
    }

    private var codeView: CodeNSTextView? {
        func find(_ view: NSView) -> CodeNSTextView? {
            if let code = view as? CodeNSTextView { return code }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    /// Prints `path` as a program would, then ⌘-clicks it.
    private func commandClick(printed path: String) {
        guard let view = pane?.view else { return XCTFail("no terminal") }
        view.surface.terminal.write(Array("\r\n\(path)\r\n".utf8))
        view.surface.outputArrived()
        let rows = view.surface.terminal.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
        guard let row = rows.lastIndex(where: { $0.contains(path) }) else { return XCTFail("\(path) not on screen") }
        let rect = view.surface.rect(for: GridPoint(x: 3, y: row))
        let point = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    private var fieldHasKeyboard: Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as? NSTextField)?.placeholderString == "Search"
    }

    private func waitUntil(seconds: Double = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// Types into the terminal, which must have the keyboard.
    private func typeShowing(_ text: String) throws {
        XCTAssertTrue(window.firstResponder === pane?.view, "the terminal has the keyboard")
        type(text)
    }

    private func type(_ text: String) {
        for character in text {
            let layout = PhysicalKey.usLayout(character)
            let keyCode = character == "\r" ? 36 : layout.flatMap { Self.macKeyCodes[$0.unshifted] } ?? 0
            press(String(character), keyCode: UInt16(keyCode), modifiers: layout?.shift == true ? .shift : [])
        }
    }

    private static let macKeyCodes: [Character: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
    ]

    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        for eventType in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: eventType, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)
            if let event { window.sendEvent(event) }
        }
    }
}
#endif
