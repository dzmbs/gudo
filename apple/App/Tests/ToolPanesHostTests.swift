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
    private var project: URL?
    private var hostId: String?
    private var driver: WindowDriver?

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let project = FileManager.default.temporaryDirectory.appending(path: "tool-panes-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        self.project = project
        try FileManager.default.createDirectory(at: project.appending(path: "src"), withIntermediateDirectories: true)
        try "PROMPT='%# '\nRPROMPT=''\nunset HISTFILE\ncd '\(project.path)'\n"
            .write(to: project.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        try #"<!doctype html><title>Fixture One</title><a href="two.html">Two</a>"#
            .write(to: project.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Fixture Two</title><p>second</p>"
            .write(to: project.appending(path: "two.html"), atomically: true, encoding: .utf8)
        try (1...200).map { "let value_\($0) = \($0);" }.joined(separator: "\n")
            .write(to: project.appending(path: "src/main.rs"), atomically: true, encoding: .utf8)
        let daemon = try TestDaemon(shell: "/bin/zsh", environment: ["ZDOTDIR": project.path])
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
        if let project { try? FileManager.default.removeItem(at: project) }
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

    private func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out: \(what)\n\(screenText)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
