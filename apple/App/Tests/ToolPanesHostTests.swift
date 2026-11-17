#if os(macOS)
import AppKit
import HostKit
import PaneLayout
import SwiftUI
import TerminalCore
import TerminalRenderer
import Vision
import XCTest
@testable import App

/// The tool panes against a real `gudo-hostd` (temporary state directory) whose zsh starts in a
/// project folder of its own: Ports lists a server a pane starts and opens its page, the browser
/// navigates by its bar and keys, a printed URL or path opens with ⌘-click, Files browses the
/// host's folder. Clicks and keys go through the window as a user's do.
@MainActor
final class ToolPanesHostTests: XCTestCase {
    private var daemon: TestDaemon?
    private var home: URL?
    private var project: URL?
    private var hostId: String?
    private var driver: WindowDriver?

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        // A home of its own: the host shares only its home's folders.
        let home = FileManager.default.temporaryDirectory.appending(path: "tool-panes-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        self.home = home
        let project = home.appending(path: "project")
        self.project = project
        try FileManager.default.createDirectory(at: project.appending(path: "src"), withIntermediateDirectories: true)
        try "PROMPT='%# '\nRPROMPT=''\nunset HISTFILE\ncd '\(project.path)'\n"
            .write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        try #"<!doctype html><title>Fixture One</title><a href="two.html">Two</a>"#
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Fixture Two</title><p>second</p>"
            .write(to: project.appending(path: "two.html"), atomically: true, encoding: .utf8)
        try (1...200).map { "let value_\($0) = \($0);" }.joined(separator: "\n")
            .write(to: project.appending(path: "src/main.rs"), atomically: true, encoding: .utf8)
        let daemon = try TestDaemon(shell: "/bin/zsh", environment: ["HOME": home.path, "ZDOTDIR": home.path])
        self.daemon = daemon
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "tool-panes-host")
        self.hostId = hostId
        let driver = try await WindowDriver.start(host: hostId)
        self.driver = driver
        try await until("the shell's prompt") { self.lastLine == "%" }
    }

    override func tearDown() async throws {
        if let driver {
            for tab in driver.model.composites.tabs { driver.model.closeMixedTab(tab.id) }
            await driver.pump(0.3)
            driver.close()
        }
        if let hostId {
            AppModel.shared.hosts.disconnect(hostId)
            AppModel.shared.hosts.remove(hostId)
        }
        daemon?.stop()
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    // MARK: Ports

    /// A server started in a pane shows in Ports by itself, a click opens its page beside the
    /// list, a second server joins the list and leaves it when it stops.
    func testPortsListsAServerFromAPaneAndOpensItsPageBeside() async throws {
        let driver = try XCTUnwrap(driver)
        let model = driver.model
        let first = try await startServer()

        try await runFromPalette("Dev Servers & Ports")
        try await until("a Ports leaf") { model.activeMixed?.focusedTool?.tool == .ports }
        let row = try await shown("localhost:\(first)")
        try await driver.click(at: NSPoint(x: row.midX, y: row.midY))
        try await until("its page opens beside the list") { model.activeMixed?.browsers.isEmpty == false }
        let mixed = try XCTUnwrap(model.activeMixed)
        XCTAssertEqual(mixed.tools.values.map(\.tool), [.ports], "the list stays")
        let page = try await page(of: try XCTUnwrap(mixed.browsers.values.first))
        try await until("the server's page shows", timeout: .seconds(15)) { page.page.title == "Fixture One" }

        // The list follows the host: a second server joins it and leaves when it stops.
        await driver.dismissOverlays()
        try focusTerminal()
        let second = try await startServer()
        _ = try await shown("localhost:\(second)")
        try await runCommand("kill %2")
        try await until("the stopped server leaves the list", timeout: .seconds(15)) {
            !model.ports.ports.contains { $0.port == second }
        }
        try await untilGone("localhost:\(second)")
        XCTAssertNotNil(try words().first { $0.text.contains("localhost:\(first)") }, "the first server stays listed")
    }

    // MARK: Browser

    /// ⌘ over a printed localhost URL underlines it and ⌘-click opens its page; the bar's ⌘L,
    /// typing and Return go to another page, Back and Forward step through them, Reload loads
    /// the page again, Esc gives up an edit, and Close takes the page away.
    func testTheBrowserOpensFromALinkAndNavigatesByItsBarAndKeys() async throws {
        let driver = try XCTUnwrap(driver)
        let model = driver.model
        let port = try await startServer()
        let address = "http://localhost:\(port)/"
        try await runCommand("echo \(address)")
        let terminalPane = try XCTUnwrap(workspace?.focusedPane)

        try hover(printed: address, modifiers: .command)
        try await until("⌘ over the URL names it") { self.workspace?.notices[terminalPane]?.hoveredURL == address }
        try hover(printed: address, modifiers: [])
        try await until("without ⌘ it is plain text") { self.workspace?.notices[terminalPane]?.hoveredURL == nil }

        try commandClick(printed: address)
        try await until("a page opens") { model.activeMixed?.focusedBrowser != nil }
        let page = try await page(of: try XCTUnwrap(model.activeMixed?.focusedBrowser))
        try await until("the server's page shows", timeout: .seconds(15)) { page.page.title == "Fixture One" }
        let field = try await addressField()
        XCTAssertEqual(field.stringValue, "localhost:\(port)", "the bar shows the short address")

        // ⌘L selects the whole address; what is typed replaces it.
        try await driver.press(KeyboardShortcut("l"))
        let editor = try await fieldEditor()
        XCTAssertEqual(editor.string, address, "the full address to edit")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (address as NSString).length), "all of it selected")
        try await driver.type(text: "localhost:\(port)/two.html")
        try await driver.type(KeyboardShortcut(.return, modifiers: []))
        try await until("Return goes there") { page.page.title == "Fixture Two" }
        XCTAssertEqual(field.stringValue, "localhost:\(port)/two.html")

        // The bar's buttons: Back, Forward, Reload at its leading end, Close at its trailing end.
        let buttons = try barButtons()
        try await driver.click(at: center(of: buttons[0]))
        try await until("Back") { page.page.title == "Fixture One" }
        try await driver.click(at: center(of: buttons[1]))
        try await until("Forward") { page.page.title == "Fixture Two" }
        _ = try await page.page.run("window.reloadMarker = 1; return 1", in: .page)
        try await driver.click(at: center(of: buttons[2]))
        try await until("Reload loads it afresh") {
            try await page.page.run("return window.reloadMarker === undefined && document.title === 'Fixture Two'", in: .page) as? Bool == true
        }

        // ⌘[ and ⌘] step through the history too.
        try await driver.press(KeyboardShortcut("["))
        try await until("⌘[ goes back") { page.page.title == "Fixture One" }
        try await driver.press(KeyboardShortcut("]"))
        try await until("⌘] goes forward") { page.page.title == "Fixture Two" }

        // Esc gives up an edit and shows the page's address again.
        try await driver.press(KeyboardShortcut("l"))
        _ = try await fieldEditor()
        try await driver.type(text: "nowhere")
        try await driver.type(KeyboardShortcut(.escape, modifiers: []))
        try await until("Esc puts the address back") { field.stringValue == "localhost:\(port)/two.html" }
        XCTAssertEqual(page.page.title, "Fixture Two", "and goes nowhere")

        // Close takes the page and its tab away; the terminal is back with the keyboard.
        let member = try XCTUnwrap(model.activeMixed?.focusedBrowser)
        try await driver.click(at: center(of: try XCTUnwrap(try barButtons().last)))
        try await until("the page closes") { model.browsers.existing(member.id) == nil && model.activeMixed == nil }
        try await until("the terminal has the keyboard") { driver.window.firstResponder === self.terminal?.view }

    }

    // MARK: File viewer

    /// ⌘-click on a printed path with a line opens the host's file beside the terminal with the
    /// line in view; it scrolls, ⌘F finds in it, and its Close button takes it away.
    func testAPrintedPathOpensTheHostsFileWhichScrollsFindsAndCloses() async throws {
        let driver = try XCTUnwrap(driver)
        let model = driver.model
        let project = try XCTUnwrap(project)
        let printed = "src/main.rs:150"
        try await runCommand("echo \(printed)")
        try commandClick(printed: printed)
        try await until("the viewer opens beside the terminal") { model.activeMixed?.focusedTool?.tool == .viewer }
        let member = try XCTUnwrap(model.activeMixed?.focusedTool)
        XCTAssertEqual(member.path, project.appending(path: "src/main.rs").path, "the path from the folder it was printed in")
        XCTAssertEqual(member.line, 150)
        XCTAssertEqual(model.activeMixed?.members.count, 1, "the terminal stays")

        var found: CodeNSTextView?
        try await until("the file's text") {
            found = driver.window.contentView.flatMap { WindowDriver.descendant(of: $0) { $0 is CodeNSTextView } } as? CodeNSTextView
            return found?.string.contains("value_200") == true
        }
        let code = try XCTUnwrap(found)
        try await until("line 150 is in view") { code.visibleRect.intersects(self.rect(of: "value_150 ", in: code)) }

        // The wheel scrolls it.
        let before = code.visibleRect.minY
        try scroll(lines: 10, over: code)
        try await until("the wheel scrolls up") { code.visibleRect.minY < before - 20 }

        // ⌘F finds in the file, not in the terminal beside it.
        try await driver.press(WorkspaceAction.find.shortcut)
        try await until("the file's find bar shows") { code.enclosingScrollView?.isFindBarVisible == true }
        XCTAssertFalse(model.isSearchShown, "the terminal's find bar stays closed")
        try await until("its field has the keyboard") { (driver.window.firstResponder as? NSTextView)?.isFieldEditor == true }
        try await driver.type(text: "value_77 ")
        try await driver.type(KeyboardShortcut(.return, modifiers: []))
        let match = (code.string as NSString).range(of: "value_77 ")
        try await until("Return selects the match") { code.selectedRange() == match }
        try await until("and shows it") { code.visibleRect.intersects(self.rect(of: "value_77 ", in: code)) }

        // Close: the leaf's leading button.
        let close = try XCTUnwrap(leafBarButtons(above: code).first)
        try await driver.click(at: center(of: close))
        try await until("the viewer closes") { model.activeMixed?.tools.isEmpty ?? true }
        try await until("the terminal has the keyboard") { driver.window.firstResponder === self.terminal?.view }
    }

    // MARK: Helpers

    private var workspace: Workspace? { driver?.model.workspace }

    private var terminal: Pane? {
        guard let workspace, let id = workspace.focusedPane else { return nil }
        return workspace.pane(id)
    }

    private var screenText: String { terminal?.view.surface.terminal.visibleText() ?? "" }

    private var lastLine: String {
        screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }

    private func focusTerminal() throws {
        let driver = try XCTUnwrap(driver)
        let view = try XCTUnwrap(terminal?.view, "the host's terminal")
        driver.window.makeFirstResponder(view)
    }

    /// `python3 -m http.server` on a free port in the project folder, as a background job; the
    /// port it serves on.
    private func startServer() async throws -> UInt16 {
        let known = Set(driver?.model.ports.ports.map(\.port) ?? [])
        type("python3 -m http.server 0 --bind 127.0.0.1 &\r")
        var port: UInt16?
        try await until("the server says its port", timeout: .seconds(15)) {
            port = self.screenText.split(separator: "\n").reversed().lazy
                .compactMap { $0.firstMatch(of: /Serving HTTP on .* port (\d+)/).flatMap { UInt16($0.1) } }
                .first { !known.contains($0) }
            return port != nil
        }
        let served = try XCTUnwrap(port)
        try await until("the host lists it", timeout: .seconds(15)) {
            self.driver?.model.ports.ports.contains { $0.port == served } == true
        }
        return served
    }

    /// Types `command` and Return, and waits for the prompt after it.
    private func runCommand(_ command: String) async throws {
        type(command + "\r")
        try await until("\(command) finishes") {
            let rows = self.screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let row = rows.lastIndex(where: { $0.hasSuffix(command) }) else { return false }
            return rows[(row + 1)...].contains("%")
        }
    }

    /// Opens the palette with ⌘K, types `title` and runs the first result with Return.
    private func runFromPalette(_ title: String) async throws {
        let driver = try XCTUnwrap(driver)
        for _ in 0..<3 where !(driver.window.firstResponder is NSTextView && driver.model.isPaletteShown) {
            await driver.dismissOverlays()
            try await driver.press(WorkspaceAction.commandPalette.shortcut)
            _ = await driver.wait(timeout: 2) { driver.window.firstResponder is NSTextView }
        }
        XCTAssertTrue(driver.model.isPaletteShown, "⌘K opens the palette")
        try await driver.type(text: title)
        try await driver.type(KeyboardShortcut(.return, modifiers: []))
        await driver.pump(0.5)
    }

    /// The page a browser leaf shows, once the leaf has made it.
    private func page(of member: BrowserMember) async throws -> BrowserPane {
        let model = try XCTUnwrap(driver?.model)
        try await until("the leaf makes its page") { model.browsers.existing(member.id)?.shownBy != nil }
        return try XCTUnwrap(model.browsers.existing(member.id))
    }

    /// The focusable controls SwiftUI drew (a key view proxy each), in window points.
    private func controls() -> [NSRect] {
        func collect(_ view: NSView) -> [NSRect] {
            let own = String(describing: Swift.type(of: view)) == "KeyViewProxy" ? [view.convert(view.bounds, to: nil)] : []
            return own + view.subviews.flatMap(collect)
        }
        return driver?.window.contentView.map { collect($0.superview ?? $0) } ?? []
    }

    /// Where the terminal shows `text`, in window points (its first cells).
    private func point(ofPrinted text: String) throws -> NSPoint {
        let view = try XCTUnwrap(terminal?.view)
        let rows = view.surface.terminal.visibleText().split(separator: "\n", omittingEmptySubsequences: false)
        let row = try XCTUnwrap(rows.lastIndex { $0.contains(text) && !$0.contains("echo") }, "\(text) on screen")
        let column = rows[row].distance(from: rows[row].startIndex, to: try XCTUnwrap(rows[row].range(of: text)).lowerBound)
        let rect = view.surface.rect(for: GridPoint(x: column + 3, y: row))
        return view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    private func hover(printed text: String, modifiers: NSEvent.ModifierFlags) throws {
        let view = try XCTUnwrap(terminal?.view)
        let window = try XCTUnwrap(driver?.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: try point(ofPrinted: text), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseMoved(with: event)
    }

    private func commandClick(printed text: String) throws {
        let window = try XCTUnwrap(driver?.window)
        let point = try point(ofPrinted: text)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
    }

    /// Where `text` is laid out in `code`, in its own coordinates.
    private func rect(of text: String, in code: NSTextView) -> NSRect {
        guard let layout = code.layoutManager, let container = code.textContainer else { return .zero }
        let range = (code.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return .zero }
        var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        rect.origin.y += code.textContainerInset.height
        return rect
    }

    /// A wheel turned `lines` toward the top over `view`.
    private func scroll(lines: Int32, over view: NSView) throws {
        let window = try XCTUnwrap(driver?.window)
        let point = view.convert(NSPoint(x: view.visibleRect.midX, y: view.visibleRect.midY), to: nil)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        wheel.location = window.convertPoint(toScreen: point)
        let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
        let target = try XCTUnwrap(window.contentView?.superview?.hitTest(point), "a view under the pointer")
        target.scrollWheel(with: event)
    }

    /// The buttons in the bar of the leaf `content` is in, leading to trailing.
    private func leafBarButtons(above content: NSView) throws -> [NSRect] {
        let scroll = content.enclosingScrollView ?? content
        let area = scroll.convert(scroll.bounds, to: nil)
        func rings(_ view: NSView) -> [NSRect] {
            let own = String(describing: Swift.type(of: view)) == "_FocusRingView" ? [view.convert(view.bounds, to: nil)] : []
            return own + view.subviews.flatMap(rings)
        }
        let above = rings(try XCTUnwrap(driver?.window.contentView))
            .filter { $0.minY >= area.maxY - 1 && $0.minY < area.maxY + 40 && $0.midX > area.minX && $0.midX < area.maxX }
        XCTAssertFalse(above.isEmpty, "the leaf's bar has buttons")
        return above.sorted { $0.minX < $1.minX }
    }

    /// The browser bar's address field.
    private func addressField() async throws -> NSTextField {
        let window = try XCTUnwrap(driver?.window)
        var found: NSTextField?
        try await until("the address field") {
            found = window.contentView.flatMap { WindowDriver.descendant(of: $0) { ($0 as? NSTextField)?.placeholderString?.hasPrefix("Search") == true } } as? NSTextField
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func fieldEditor() async throws -> NSTextView {
        let window = try XCTUnwrap(driver?.window)
        try await until("the address field takes the keyboard") {
            (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        // The whole address is selected a turn after the field takes the keyboard.
        try await Task.sleep(for: .milliseconds(300))
        return try XCTUnwrap(window.firstResponder as? NSTextView)
    }

    /// The browser bar's buttons, leading to trailing (each draws a focus ring view).
    private func barButtons() throws -> [NSRect] {
        let field = try XCTUnwrap(driver?.window.contentView.flatMap {
            WindowDriver.descendant(of: $0) { ($0 as? NSTextField)?.placeholderString?.hasPrefix("Search") == true }
        })
        let bar = field.convert(field.bounds, to: nil)
        func rings(_ view: NSView) -> [NSRect] {
            let own = String(describing: Swift.type(of: view)) == "_FocusRingView" ? [view.convert(view.bounds, to: nil)] : []
            return own + view.subviews.flatMap(rings)
        }
        let buttons = rings(try XCTUnwrap(driver?.window.contentView)).filter { abs($0.midY - bar.midY) < 4 && !$0.intersects(bar) }
        XCTAssertGreaterThanOrEqual(buttons.count, 4, "Back, Forward, Reload and Close: \(buttons)")
        return buttons.sorted { $0.minX < $1.minX }
    }

    private func center(of rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }

    // MARK: Words on screen

    struct Word {
        var text: String
        var frame: NSRect
    }

    /// The words drawn in the window, read off its pixels, in window points.
    private func words() throws -> [Word] {
        let window = try XCTUnwrap(driver?.window)
        let view = try XCTUnwrap(window.contentView?.superview)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = view.bounds.size
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Word(text: text, frame: NSRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height))
        }
    }

    /// Where `text` is drawn: the part of a line that starts with it.
    private func shown(_ text: String, timeout: Duration = .seconds(15)) async throws -> NSRect {
        var found: NSRect?
        try await until("“\(text)” shows", timeout: timeout) {
            guard let line = ((try? self.words()) ?? []).first(where: { $0.text.contains(text) }) else { return false }
            let start = line.text.range(of: text).map { line.text.distance(from: line.text.startIndex, to: $0.lowerBound) } ?? 0
            let share = line.frame.width / CGFloat(max(line.text.count, 1))
            found = NSRect(x: line.frame.minX + share * CGFloat(start), y: line.frame.minY, width: share * CGFloat(text.count), height: line.frame.height)
            return true
        }
        return try XCTUnwrap(found)
    }

    private func untilGone(_ text: String) async throws {
        try await until("“\(text)” goes") { !((try? self.words()) ?? []).contains { $0.text.contains(text) } }
    }

    // MARK: Keys

    private func type(_ text: String) {
        for character in text {
            let layout = PhysicalKey.usLayout(character)
            let keyCode = character == "\r" ? 36 : layout.flatMap { Self.macKeyCodes[$0.unshifted] } ?? 0
            press(String(character), keyCode: UInt16(keyCode), modifiers: layout?.shift == true ? .shift : [])
        }
    }

    private static let macKeyCodes: [Character: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = driver?.window else { return }
        for eventType in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: eventType, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)
            if let event { window.sendEvent(event) }
        }
    }

    private func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while (try? await condition()) != true {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out: \(what)\n\(screenText)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
