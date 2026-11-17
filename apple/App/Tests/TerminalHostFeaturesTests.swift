#if os(macOS)
import AppKit
import HostKit
import SwiftUI
import TerminalCore
import TerminalRenderer
import XCTest
@testable import App

/// The terminal against a real `gudo-hostd` running zsh on a temporary state directory: keys and
/// pastes reach the shell, the shell's command marks show, scrolling to the top pages older
/// output in from the host, and a shell that exits takes its pane with it.
@MainActor
final class TerminalHostFeaturesTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    private var daemon: TestDaemon?
    private var zshDirectory: URL?
    private var hostId: String?
    private var window: NSWindow?
    private var model: WindowModel?

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let zsh = FileManager.default.temporaryDirectory.appending(path: "terminal-host-zsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)
        try "PROMPT='%# '\nRPROMPT=''\nunset HISTFILE\n".write(to: zsh.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        zshDirectory = zsh
        let daemon = try TestDaemon(shell: "/bin/zsh", environment: ["ZDOTDIR": zsh.path])
        self.daemon = daemon
        hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "terminal-host-features")
        try await openWindow()
    }

    override func tearDown() async throws {
        closeWindow()
        if let hostId { AppModel.shared.hosts.remove(hostId) }
        daemon?.stop()
        if let zshDirectory { try? FileManager.default.removeItem(at: zshDirectory) }
    }

    // MARK: Typing and pasting

    func testKeysAndABracketedPasteReachTheShell() async throws {
        try await runCommand("echo typed-$((40+2))", showing: "typed-42")
        XCTAssertTrue(screenText.contains("typed-42"), screenText)

        let view = try XCTUnwrap(pane?.view)
        view.pasteText("echo one\necho two")
        try await until("the paste waits on the command line") { self.screenText.contains("echo two") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(screenText.contains("\none\n"), "a bracketed paste runs nothing: \(screenText)")
        press("c", keyCode: 8, modifiers: .control)
        try await until("Control-C clears the line") { self.lastLine == "%" }
    }

    // MARK: Command marks

    func testCommandsGetMarksAndCommandUpJumpsToTheirPrompts() async throws {
        try await runCommand("seq 1 120", showing: "120")
        try await runCommand("false")
        let workspace = try XCTUnwrap(model?.workspace)
        let pane = try XCTUnwrap(pane)
        let marks = try XCTUnwrap(PaneCommandMarks.of(pane), "a host pane has command marks")
        try await until("the failed command is marked") {
            (0..<pane.view.surface.terminal.size.rows).contains { marks.block(atViewportRow: $0)?.status == .failed(1) }
        }

        WorkspaceAction.previousPrompt.perform(on: workspace, window: try XCTUnwrap(model))
        WorkspaceAction.previousPrompt.perform(on: workspace, window: try XCTUnwrap(model))
        try await until("⌘↑ shows the seq prompt at the top") {
            pane.view.surface.terminal.visibleText().split(separator: "\n").first?.contains("seq 1 120") == true
        }
        XCTAssertEqual(marks.block(atViewportRow: 0)?.status, .succeeded)
        WorkspaceAction.nextPrompt.perform(on: workspace, window: try XCTUnwrap(model))
        WorkspaceAction.nextPrompt.perform(on: workspace, window: try XCTUnwrap(model))
        WorkspaceAction.nextPrompt.perform(on: workspace, window: try XCTUnwrap(model))
        try await until("⌘↓ past the last prompt returns to the bottom") { pane.view.surface.terminal.viewportAtBottom }
    }

    // MARK: Scrollback from the host

    func testCommandHomeOnAReopenedWindowPagesTheOldestOutputIn() async throws {
        try await runCommand("seq 1 5000", showing: "5000")
        closeWindow()
        try await openWindow()
        let pane = try XCTUnwrap(pane)
        try await until("the reopened pane shows the end") { self.screenText.contains("5000") }
        let held = pane.view.surface.terminal.scrollbar.total

        pressCommandHome()
        try await until("older rows arrive from the host", timeout: .seconds(20)) {
            pane.view.surface.terminal.scrollbar.total > held
        }
        try await until("⌘Home again reaches the first row", timeout: .seconds(30)) {
            self.pressCommandHome()
            return pane.view.surface.terminal.visibleText().split(separator: "\n").contains { $0 == "1" }
        }
    }

    /// ⌘- on a reopened window grows the grid: its new top rows are the host's older output,
    /// in order, never blank rows.
    func testZoomingOutFillsTheNewRowsFromTheHost() async throws {
        try await runCommand("seq 1 5000", showing: "5000")
        closeWindow()
        try await openWindow()
        let workspace = try XCTUnwrap(model?.workspace)
        let pane = try XCTUnwrap(pane)
        try await until("the reopened pane shows the end") { self.screenText.contains("5000") }
        let rows = pane.view.surface.terminal.size.rows

        WorkspaceAction.decreaseFontSize.perform(on: workspace, window: try XCTUnwrap(model))
        WorkspaceAction.decreaseFontSize.perform(on: workspace, window: try XCTUnwrap(model))
        try await until("more rows") { pane.view.surface.terminal.size.rows > rows }
        XCTAssertEqual(pane.view.surface.grid.map { Int($0.rows) }, pane.view.surface.terminal.size.rows, "the host took the new grid")
        try await until("every row shows output", timeout: .seconds(10)) {
            let numbers = self.screenText.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return numbers.count >= pane.view.surface.terminal.size.rows - 3
        }
        let numbers = screenText.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(numbers, Array((numbers.first ?? 0)...(numbers.last ?? 0)), "in order, none missing")
        XCTAssertEqual(numbers.last, 5000)
    }

    // MARK: Exit

    func testAShellThatExitsClosesItsPaneAndTheOtherTakesTheKeyboard() async throws {
        let model = try XCTUnwrap(model)
        let workspace = try XCTUnwrap(model.workspace)
        let first = try XCTUnwrap(workspace.focusedPane)
        WorkspaceAction.splitRight.perform(on: workspace, window: model)
        try await until("the split's shell is live") {
            guard let id = workspace.focusedPane, id != first, let pane = workspace.pane(id) else { return false }
            return pane.view.window != nil && pane.view.surface.terminal.visibleText().contains("%")
        }
        let second = try XCTUnwrap(workspace.focusedPane)
        try XCTUnwrap(window).makeFirstResponder(try XCTUnwrap(workspace.pane(second)?.view))

        type("exit\r")
        try await until("the pane closes") { workspace.session.activeTab?.root.panes.contains(second) == false }
        try await until("the other pane is focused") { workspace.focusedPane == first }
        try await until("and has the keyboard") { self.window?.firstResponder === workspace.pane(first)?.view }
        XCTAssertTrue(window?.firstResponder === workspace.pane(first)?.view)
    }

    // MARK: Helpers

    private func openWindow() async throws {
        let hostId = try XCTUnwrap(hostId)
        let model = WindowModel(app: .shared)
        model.start()
        let frame = NSRect(x: -30000, y: -30000, width: 1000, height: 700)
        let window = OffscreenWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        self.model = model
        self.window = window
        model.isSidebarShown = false
        model.show(.host(hostId))
        // On screen behind another app's window: an offscreen test window's scene is in the background.
        model.isOnScreen = true
        try await until("a live shell", timeout: .seconds(20)) {
            guard let pane = self.pane else { return false }
            return pane.connection == .live && pane.view.window != nil && self.lastLine == "%"
        }
        window.makeFirstResponder(try XCTUnwrap(pane?.view))
    }

    private func closeWindow() {
        window?.close()
        model?.close()
        if let hostId { AppModel.shared.hosts.disconnect(hostId) }
        window = nil
        model = nil
    }

    private var pane: Pane? {
        guard let workspace = model?.workspace, let id = workspace.focusedPane else { return nil }
        return workspace.pane(id)
    }

    private var screenText: String { pane?.view.surface.terminal.visibleText() ?? "" }

    private var lastLine: String {
        screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    }

    /// Types `command` and Return, and waits for the prompt after the row `showing` ends on
    /// (the command line itself by default).
    private func runCommand(_ command: String, showing: String? = nil) async throws {
        type(command + "\r")
        let shown = showing ?? "% \(command)"
        try await until("\(command) finishes") {
            let rows = self.screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let row = rows.lastIndex(where: { $0 == shown }) else { return false }
            return rows[(row + 1)...].contains("%")
        }
    }

    private func until(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TimedOut(what: what, screen: screenText) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private struct TimedOut: Error, CustomStringConvertible {
        let what: String
        let screen: String
        var description: String { "timed out: \(what)\n\(screen)" }
    }

    private func pressCommandHome() {
        guard let view = pane?.view else { return }
        let home = UnicodeScalar(UInt32(NSHomeFunctionKey)).map { String(Character($0)) } ?? ""
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [.command, .function], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil, characters: home, charactersIgnoringModifiers: home,
                isARepeat: false, keyCode: 115)
            else { continue }
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
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
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
    ]

    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window else { return }
        let control = characters.unicodeScalars.first.map { String(UnicodeScalar(UInt8($0.value & 0x1F))) }
        let sent = modifiers.contains(.control) ? control ?? characters : characters
        for eventType in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: eventType, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: sent,
                charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)
            if let event { window.sendEvent(event) }
        }
    }
}
#endif
