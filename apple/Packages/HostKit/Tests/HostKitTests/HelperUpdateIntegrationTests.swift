import Foundation
@testable import HostKit
import PaneLayout
import Testing
import UnnamedCore

/// "Update Helper" end to end on this Mac: a real `unnamed-hostd` installed as a copy in a
/// scratch directory reports its build and host name; the app's manifest says it bundles a
/// newer build for this platform; `HostsModel.updateHelper` streams it over the daemon
/// connection; the daemon checks it, swaps it in and restarts in place (`exec`); the same
/// connection comes back on a new daemon run with the layout restored.
@MainActor
@Suite(.serialized) struct HelperUpdateIntegrationTests {
    @Test func updateOverTheConnectionAndComeBack() async throws {
        let scratch = temporaryDirectory()
        let installed = scratch.appending(path: "bin/unnamed-hostd")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: LocalDaemon.defaultBinary, to: installed)
        // The "bundled" build: the same executable, which the manifest says is newer.
        let bundle = scratch.appending(path: "bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: LocalDaemon.defaultBinary, to: bundle.appending(path: "hostd-macos"))
        let arch = daemonArch()
        try """
            {"builds": [{"file": "hostd-macos", "os": "macos", "arch": "\(arch)", "build": "test-newer", "built_unix": 4102444800, "protocol": \(protocolLevel())}]}
            """.write(to: bundle.appending(path: "hostd-manifest.json"), atomically: true, encoding: .utf8)
        let manifest = try #require(BundledDaemons.load(manifest: bundle.appending(path: "hostd-manifest.json")))

        let daemon = try LocalDaemon(binary: installed)
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        configuration.mirrorVt = true
        configuration.bundledDaemons = { manifest }
        let model = HostsModel(
            secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()),
            configuration: configuration)
        let hostId = try await model.pair(try PairingTicket(try await daemon.ticket()))
        let connection = try #require(model.connection(hostId) as? DaemonConnection)

        // Named after this machine; the daemon can replace itself; the app's build is newer.
        let info = try #require(connection.daemonInfo)
        #expect(info.selfUpgrade)
        #expect(info.os == "macos")
        #expect(!info.hostname.isEmpty)
        #expect(model.record(hostId)?.name == MachineName.display(info.hostname))
        #expect(model.record(hostId)?.nameSource == .machine)
        let advice = try #require(model.helperAdvice(hostId))
        #expect(advice.kind == .update)
        #expect(advice.method == .connection)

        connection.layout.apply(.split(try #require(connection.layout.session.activeTab?.focused), .horizontal))
        try await eventually("split", timeout: .seconds(10)) { connection.layout.session.panes.count == 2 }
        let epoch = connection.epoch
        let started = ContinuousClock.now
        try await model.updateHelper(hostId)
        print("helper update over the connection: \(ContinuousClock.now - started)")

        // A new daemon run, live, with the layout it saved.
        #expect(connection.epoch != epoch)
        #expect(connection.status.isLive)
        try await eventually("layout restored", timeout: .seconds(10)) { connection.layout.session.panes.count == 2 }
        #expect(model.helperUpdates[hostId] == nil)
        #expect(FileManager.default.fileExists(atPath: installed.path + ".prev"))
        // Still the process the test started (restarted in place).
        let pane = try #require(connection.layout.session.activeTab?.focused)
        let backend = try connection.makeBackend(for: pane)
        let sink = EventSink()
        backend.start(events: sink.handler)
        backend.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        Array("echo updated-$((20+3))\r".utf8).withUnsafeBytes { backend.write($0) }
        try await eventually("echo after the update", timeout: .seconds(15)) { connection.paneText(pane)?.contains("updated-23") == true }
        backend.terminate()
        model.disconnect(hostId)
    }

    /// `std::env::consts::ARCH` of this Mac.
    private func daemonArch() -> String {
        #if arch(arm64)
        "aarch64"
        #else
        "x86_64"
        #endif
    }
}
