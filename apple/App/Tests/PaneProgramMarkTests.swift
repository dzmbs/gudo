import DesignSystem
import HostKit
import PaneLayout
import Synchronization
import XCTest
@testable import App

/// A pane's mark follows the program its host reports in front of the terminal, read with its
/// arguments, so an agent run by an interpreter or a launcher still shows as itself.
@MainActor
final class PaneProgramMarkTests: XCTestCase {
    private final class Reporting: ForegroundProgramReporting, Sendable {
        private let follower = Mutex<(@Sendable (ForegroundProgram?) -> Void)?>(nil)
        var isFollowed: Bool { follower.withLock { $0 != nil } }
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func write(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func terminate() {}
        func onForegroundProgramChange(_ onChange: @escaping @Sendable (ForegroundProgram?) -> Void) {
            follower.withLock { $0 = onChange }
        }
        func report(_ program: ForegroundProgram?) { follower.withLock { $0 }?(program) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testTheHostsReportNamesThePaneWithItsArguments() async throws {
        let session = Session()
        let pane = try XCTUnwrap(session.activeTab?.focused)
        let backend = Reporting()
        let workspace = Workspace(layout: LocalLayoutStore(session: session)) { _ in backend }
        defer { workspace.close() }
        try await waitUntil { workspace.pane(pane) != nil && backend.isFollowed }

        let shown: [(ForegroundProgram, String)] = [
            (ForegroundProgram(name: "node", arguments: ["node", "/home/me/.pi/agent/install/releases/1.4.0/node_modules/.bin/pi"]), "pi"),
            (ForegroundProgram(name: "pi", arguments: ["pi"]), "pi"),
            (ForegroundProgram(name: "python3.12", arguments: ["python3.12", "-m", "http.server", "8000"]), "python"),
            (ForegroundProgram(name: "sudo", arguments: ["sudo", "-u", "root", "htop"]), "htop"),
            (ForegroundProgram(name: "nvim", arguments: ["nvim", "README.md"]), "neovim"),
            (ForegroundProgram(name: "zsh", arguments: ["-zsh"]), "zsh"),
            (ForegroundProgram(name: "mystery", arguments: ["mystery", "--flag"]), "mystery"),
        ]
        for (program, id) in shown {
            backend.report(program)
            try await waitUntil { workspace.programIdentity(of: pane).id == id }
            XCTAssertEqual(workspace.programIdentity(of: pane).id, id, "\(program.arguments)")
        }
        XCTAssertEqual(workspace.programIdentity(of: pane).symbol, "terminal", "an unknown program keeps the terminal glyph")
    }
}
