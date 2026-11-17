#if os(macOS)
import AppKit
import DesignSystem
import GudoCore
import HostKit
import SwiftUI
import TerminalRenderer
import XCTest
@testable import App

/// A window opening on a host it is the only client of: the host's terminals take the window's
/// size and nothing says someone else decides it.
@MainActor
final class LaunchSizingTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    private func sceneWindow(model: WindowModel, width: CGFloat) -> NSWindow {
        let frame = NSRect(x: -30000, y: -30000, width: width, height: 760)
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.titlebarAppearsTransparent = true
        let controller = NSHostingController(rootView: ThemedRoot { WindowContent(request: nil, model: model).environment(AppModel.shared) })
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }

    private func until(_ what: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private struct Observed {
        var source: PaneSizingSource?
        var hostGrid: (cols: Int, rows: Int)
        var viewGrid: TerminalSurface.Grid?
    }

    private func observe(_ pane: Pane, on connection: DaemonConnection) -> Observed {
        let session = connection.multiplayer
        let source = connection.sizing[pane.id].flatMap { state in
            connection.meta[pane.id].flatMap { metadata in
                PaneSizingSource.resolve(
                    state, myPeer: session.myPeer, policy: metadata.sizePolicy, isLocalDriver: pane.isSizingTap,
                    othersConnected: session.peers.keys.contains { $0 != session.myPeer })
            }
        }
        let size = pane.view.surface.terminal.size
        return Observed(source: source, hostGrid: (size.cols, size.rows), viewGrid: pane.view.surface.grid)
    }

    func testALoneWindowSizesItsHostsTerminalsAtLaunchAndAfterARelaunch() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "needs TEST_RUNNER_GUDO_MOCK=1")
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let hostId = try await AppModel.shared.hosts.pair(PairingTicket(try await daemon.ticket()), name: "launch-sizing")
        defer { AppModel.shared.hosts.remove(hostId) }

        for launch in 0..<2 {
            let model = WindowModel(app: .shared)
            model.start()
            let window = sceneWindow(model: model, width: launch == 0 ? 1800 : 1260)
            defer {
                window.close()
                model.close()
                AppModel.shared.hosts.disconnect(hostId)
            }
            model.isSidebarShown = false
            model.show(.host(hostId))
            try await until("live pane") {
                guard let workspace = model.workspace, let id = workspace.focusedPane, let pane = workspace.panes[id] else { return false }
                return pane.connection == .live && pane.view.surface.grid != nil
            }
            // On screen behind another app's window: shown, not active (an offscreen test
            // window's scene is in the background).
            model.isOnScreen = true
            let workspace = try XCTUnwrap(model.workspace)
            let connection = try XCTUnwrap(workspace.host as? DaemonConnection)
            let pane = try XCTUnwrap(workspace.focusedPane.flatMap { workspace.panes[$0] })
            var sources: [PaneSizingSource] = []
            try await until("the host's grid is the window's (launch \(launch))", timeout: .seconds(10)) {
                let observed = observe(pane, on: connection)
                if let source = observed.source, sources.last != source { sources.append(source) }
                guard let grid = observed.viewGrid else { return false }
                return observed.hostGrid == (Int(grid.cols), Int(grid.rows))
            }
            XCTAssertEqual(sources, [], "launch \(launch)")
        }
    }
}

/// A `gudo-hostd` of the workspace's debug build (`GUDO_HOSTD_BIN` names another) on a
/// temporary state directory, relays off, on this machine's loopback.
final class TestDaemon {
    let binary: URL
    let stateDirectory: URL
    private let process = Process()

    init(shell: String = "/bin/sh", environment: [String: String] = [:]) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        binary = ProcessInfo.processInfo.environment["GUDO_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/gudo-hostd")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "no daemon at \(binary.path): run `cargo build -p hostd` first")
        stateDirectory = FileManager.default.temporaryDirectory.appending(path: "launch-sizing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        process.executableURL = binary
        process.arguments = ["--state-dir", stateDirectory.path, "run", "--no-relay", "--bind", "127.0.0.1:0", "--shell", shell]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func ticket() async throws -> String {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let pipe = Pipe()
            let pair = Process()
            pair.executableURL = binary
            pair.arguments = ["--state-dir", stateDirectory.path, "pair", "--json"]
            pair.standardOutput = pipe
            pair.standardError = FileHandle.nullDevice
            try pair.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            pair.waitUntilExit()
            if pair.terminationStatus == 0,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["running"] as? Bool == true, (object["addrs"] as? [Any])?.isEmpty == false,
               let ticket = object["ticket"] as? String
            {
                return ticket
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("the daemon did not come up")
    }

    func signal(_ signal: Int32) {
        kill(process.processIdentifier, signal)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: stateDirectory)
    }
}
#endif
