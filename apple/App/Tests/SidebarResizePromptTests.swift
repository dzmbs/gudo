#if os(macOS)
import AppKit
import HostKit
import SwiftUI
import TerminalCore
import TerminalRenderer
import XCTest
@testable import App

/// Hiding the sidebar widens the pane once: zsh redraws its prompt with the right prompt at the
/// new right edge, and no copy of it stays where the old edge was. Lines from before the resize
/// keep theirs where it was, as in Ghostty: zsh redraws only the prompt it is editing.
@MainActor
final class SidebarResizePromptTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    func testHidingTheSidebarLeavesOneRightPrompt() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let zsh = FileManager.default.temporaryDirectory.appending(path: "sidebar-resize-zsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: zsh) }
        try "PROMPT='%# '\nRPROMPT='[right]'\nunset HISTFILE\n".write(to: zsh.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
        let daemon = try TestDaemon(shell: "/bin/zsh", environment: ["ZDOTDIR": zsh.path])
        defer { daemon.stop() }
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "sidebar-resize")
        defer { AppModel.shared.hosts.remove(hostId) }

        let model = WindowModel(app: .shared)
        model.start()
        let frame = NSRect(x: -30000, y: -30000, width: 1100, height: 600)
        let window = OffscreenWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        defer {
            window.close()
            model.close()
            AppModel.shared.hosts.disconnect(hostId)
        }
        model.isSidebarShown = true
        model.show(.host(hostId))
        model.isOnScreen = true
        var pane: Pane? { model.workspace?.focusedPane.flatMap { model.workspace?.pane($0) } }
        var rows: [String] { (pane?.view.surface.terminal.visibleText() ?? "").components(separatedBy: "\n") }
        func rightPromptRows() -> [String] { rows.filter { $0.contains("[right]") } }
        func until(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !condition() {
                guard ContinuousClock.now < deadline else { return XCTFail("timed out: \(what)\n\(rows.joined(separator: "\n"))") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await until("a live prompt") { pane?.connection == .live && rightPromptRows().count == 1 }
        // A command before the resize: its line keeps the right prompt where the old edge was.
        pane?.view.onInput?(Array("echo before\r".utf8))
        try await until("a second prompt") { rows.contains("before") && rightPromptRows().count == 2 }
        let narrow = try XCTUnwrap(pane?.view.surface.terminal.size.cols)
        let resizes = try XCTUnwrap(pane?.resizesSent)

        model.isSidebarShown = false
        try await until("the pane widens") { (pane?.view.surface.terminal.size.cols ?? 0) > narrow + 10 }
        let wide = try XCTUnwrap(pane?.view.surface.terminal.size.cols)
        try await until("the prompt is redrawn at the new edge") {
            rightPromptRows().contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("[right]") && $0.count >= wide - 2 }
        }
        try await Task.sleep(for: .seconds(1))
        let screen = rows.joined(separator: "\n")
        XCTAssertEqual(pane?.resizesSent, resizes + 1, "one resize for the gesture")
        XCTAssertEqual(rightPromptRows().count, 2, "the command's line and the new prompt's, no copy:\n\(screen)")
        XCTAssertEqual(rows.filter { $0.hasPrefix("%") }.count, 2, "the command's prompt and the new one:\n\(screen)")
        let prompt = try XCTUnwrap(rows.last { $0.hasPrefix("%") })
        XCTAssertEqual(prompt.components(separatedBy: "[right]").count, 2, "one right prompt on the prompt's line:\n\(screen)")
    }
}
#endif
