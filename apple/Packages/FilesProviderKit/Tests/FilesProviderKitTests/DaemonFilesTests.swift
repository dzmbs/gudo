#if os(macOS)
import FileProvider
import Foundation
@testable import FilesProviderKit
import HostKit
import Testing
import UnnamedCore

/// The repository root (this file is apple/Packages/FilesProviderKit/Tests/FilesProviderKitTests/…).
nonisolated let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A local `unnamed-hostd` with relays off and its own home (`cargo build -p hostd` first, or
/// `UN_HOSTD_BIN`).
nonisolated final class LocalDaemon {
    let binary: URL
    let stateDir = temporaryDirectory()
    let home = temporaryDirectory()
    private let process = Process()

    init() throws {
        binary = ProcessInfo.processInfo.environment["UN_HOSTD_BIN"].map(URL.init(fileURLWithPath:))
            ?? repoRoot.appending(path: "target/debug/unnamed-hostd")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TestFailure("no daemon at \(binary.path): run `cargo build -p hostd` first")
        }
        process.executableURL = binary
        process.arguments = ["--state-dir", stateDir.path, "run", "--no-relay", "--bind", "127.0.0.1:0", "--shell", "/bin/sh"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
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
            pair.arguments = ["--state-dir", stateDir.path, "pair", "--json"]
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
        throw TestFailure("the daemon did not come up")
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: stateDir)
        try? FileManager.default.removeItem(at: home)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// End to end: pair in the app's model, share the host the way the app does, dial it the way
/// the extension does, and browse, create, edit, rename, fetch and delete in the daemon's home.
@MainActor
@Suite(.serialized) struct DaemonFilesTests {
    @Test func theExtensionsPathToARealDaemon() async throws {
        let daemon = try LocalDaemon()
        var configuration = HostsModel.Configuration()
        configuration.relay = .disabled
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()), configuration: configuration)
        let hostId = try await model.pair(try PairingTicket(try await daemon.ticket()), name: "local")

        let share = FilesShare(directory: temporaryDirectory(), secrets: MemorySecretStore())
        try share.publish(hosts: model.records, appSecrets: model.secrets, relay: RelaySettings())
        let client = try share.connect(hostId: hostId, listener: NoEvents(), relayBase: .disabled)
        let core = FilesProviderCore(remote: client, identifiers: share.identifiers(for: hostId), downloads: temporaryDirectory())

        try Data("from the host".utf8).write(to: daemon.home.appending(path: "hello.txt"))
        let root = try await core.item(for: .rootContainer)
        #expect(root.path == daemon.home.path)
        let hello = try #require(try await core.children(of: .rootContainer).first { $0.filename == "hello.txt" })
        #expect(hello.documentSize == 13)

        let folder = try await core.create(name: "From Files", in: .rootContainer, isFolder: true, contents: nil)
        let upload = temporaryDirectory().appending(path: "note.md")
        try Data("# written in Files".utf8).write(to: upload)
        let note = try await core.create(name: "note.md", in: folder.itemIdentifier, isFolder: false, contents: upload)
        #expect(try String(contentsOf: daemon.home.appending(path: "From Files/note.md"), encoding: .utf8) == "# written in Files")

        try Data("# edited".utf8).write(to: upload)
        let edited = try await core.modify(
            note.itemIdentifier, changes: [.contents, .filename], name: "renamed.md", parent: folder.itemIdentifier,
            baseVersion: note.itemVersion.contentVersion, contents: upload)
        #expect(edited.itemIdentifier == note.itemIdentifier)
        #expect(try String(contentsOf: daemon.home.appending(path: "From Files/renamed.md"), encoding: .utf8) == "# edited")

        let (fetched, _) = try await core.fetchContents(of: hello.itemIdentifier)
        #expect(try String(contentsOf: fetched, encoding: .utf8) == "from the host")

        try await core.delete(folder.itemIdentifier)
        #expect(!FileManager.default.fileExists(atPath: daemon.home.appending(path: "From Files").path))
        await #expect(throws: NSFileProviderError(.noSuchItem)) { try await core.item(for: note.itemIdentifier) }
    }
}
#endif
