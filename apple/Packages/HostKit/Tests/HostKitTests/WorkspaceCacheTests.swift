import Foundation
@testable import HostKit
import PaneLayout
import Security
import Synchronization
import TerminalCore
import Testing
import GudoCore

/// A terminal showing `lines` (and scrollback above them when there are more than its rows).
nonisolated func terminal(_ lines: [String], cols: UInt16 = 80, rows: UInt16 = 24) -> Terminal {
    let terminal = Terminal(cols: cols, rows: rows) { _ in }
    terminal.write(Array(lines.joined(separator: "\r\n").utf8))
    return terminal
}

/// What a held pane's input went through.
nonisolated final class HeldStates: Sendable {
    private let states = Mutex<[DaemonPaneBackend.HeldInputState]>([])
    var all: [DaemonPaneBackend.HeldInputState] { states.withLock { $0 } }
    func append(_ state: DaemonPaneBackend.HeldInputState) { states.withLock { $0.append(state) } }
}

/// A Keychain that refuses every read and write, as a locked device's does.
nonisolated final class RefusingSecretStore: SecretStore {
    func data(for key: String) throws -> Data? { throw refusal(key) }
    func set(_ data: Data, for key: String) throws { throw refusal(key) }
    func remove(_ key: String) throws { throw refusal(key) }

    private func refusal(_ key: String) -> SecretStoreError {
        SecretStoreError(status: errSecInteractionNotAllowed, operation: key)
    }
}

/// The layout `sampleLayout()` describes, as a session (one tab 10: 1 | (2 / 3), 3 focused).
func sampleSession() -> Session {
    LayoutConversion.session(sampleLayout())
}

/// Instant start: what is saved of a host's workspace, how it is bounded and invalidated, how a
/// connection shows it before the daemon answers and gives way to the daemon's state, and what
/// happens to input typed over a saved screen.
@MainActor
struct WorkspaceCacheTests {
    private func cached(
        hostId: String = "h", daemonId: String? = "d1", sessionId: UInt64? = 7, panes: [UInt64: CachedPane]? = nil,
        savedAt: Date = .now
    ) -> CachedWorkspace {
        let screens = panes ?? [1: CachedPane(terminal: terminal(["$ make", "ok"]), title: "make", cwd: "/srv/api")]
        var projects = HostProjects()
        projects.apply(.put(ProjectInfo(id: "p", name: "api", color: 1, order: 0, updated: 1)))
        projects.apply(.setTab(TabId(10), Membership(project: "p", rank: 0)))
        return CachedWorkspace(
            hostId: hostId, daemonId: daemonId, sessionId: sessionId, sessionName: "main", session: sampleSession(),
            projects: projects, panes: screens, savedAt: savedAt)
    }

    // MARK: The store

    @Test func roundTripKeepsTheLayoutNamesAndScreens() throws {
        let store = WorkspaceCacheStore(directory: temporaryDirectory(), secrets: MemorySecretStore())
        let source = terminal((1...60).map { "line \($0)" } + ["$ cargo test", "test result: ok"])
        source.scrollViewport(by: -5)
        let pane = CachedPane(terminal: source, title: "cargo", cwd: "/srv/api")
        #expect(pane.screen != nil)
        #expect(pane.scrolledBack == 5)
        let workspace = cached(panes: [1: pane, 2: CachedPane(title: "logs")])
        try store.save(workspace)

        let loaded = try #require(store.load(hostId: "h", daemonId: "d1", sessionId: 7))
        #expect(loaded == workspace)
        #expect(loaded.session.tabs.map(\.id) == [TabId(10)])
        #expect(loaded.projects.members[TabId(10)]?.project == "p")

        // The saved screen draws the same text, scrolled where it was.
        let restored = Terminal(cols: 80, rows: 24) { _ in }
        try restored.restore(snapshot: try #require(loaded.panes[1]?.screen))
        _ = try restored.appendHistory(loaded.panes[1]!.history)
        source.scrollToBottom()
        #expect(restored.visibleText() == source.visibleText())
        #expect(restored.visibleText().contains("test result: ok"))
    }

    @Test func theFileIsOwnerOnlyAndOutOfBackups() throws {
        let store = WorkspaceCacheStore(directory: temporaryDirectory().appending(path: "Workspaces"), secrets: MemorySecretStore())
        try store.save(cached())
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file(for: "h").path)
        #if os(macOS)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #endif
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        // Compressed, never plain text on disk.
        let raw = try Data(contentsOf: store.file(for: "h"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("/srv/api"))
    }

    @Test func boundsKeepTheActiveTabFirstAndDropWhatDoesNotFit() throws {
        var limits = WorkspaceCacheLimits()
        let big = CachedPane(title: "x", screen: Data(repeating: 1, count: 300), history: Data(repeating: 2, count: 100))
        limits.screenBytes = 1000
        limits.hostBytes = 900
        var workspace = cached(panes: [1: big, 2: big, 3: big, 99: big])
        // Pane 3 is focused in the active tab: it is kept first, then 1, then 2 does not fit.
        let bounded = workspace.bounded(by: limits)
        #expect(bounded.panes[99] == nil, "a pane the layout no longer has goes")
        #expect(bounded.panes[3]?.screen != nil)
        #expect(bounded.panes[1]?.screen != nil)
        #expect(bounded.panes[2]?.screen == nil)
        #expect(bounded.panes[2]?.title == "x", "names stay when a screen does not fit")

        // A single screen over the per-pane limit is never kept.
        limits.screenBytes = 200
        workspace = cached(panes: [3: big])
        #expect(workspace.bounded(by: limits).panes[3]?.screen == nil)

        // Scrollback above a screen is cut to its limit, at a record boundary.
        let long = terminal((1...5000).map { "row \($0) " + String(repeating: "x", count: 60) })
        let pane = CachedPane(terminal: long, title: "", cwd: nil)
        #expect(pane.history.count <= WorkspaceCacheLimits().historyBytes)
        let restored = Terminal(cols: 80, rows: 24) { _ in }
        try restored.restore(snapshot: try #require(pane.screen))
        _ = try restored.appendHistory(pane.history)
        #expect(restored.visibleText().contains("row 5000"))
    }

    @Test func aCacheThatIsNoLongerTheHostsIsDropped() throws {
        let store = WorkspaceCacheStore(directory: temporaryDirectory(), secrets: MemorySecretStore())
        try store.save(cached())
        #expect(store.load(hostId: "h", daemonId: "d2", sessionId: 7) == nil, "paired again with another daemon")
        #expect(!FileManager.default.fileExists(atPath: store.file(for: "h").path))

        try store.save(cached())
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 8) == nil, "another session")
        try store.save(cached())
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: nil) != nil, "no session remembered yet")

        try store.save(cached(savedAt: .now.addingTimeInterval(-15 * 24 * 3600)))
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil, "too old")

        try Data("UNWSgarbage".utf8).write(to: store.file(for: "h"))
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil, "unreadable")
        #expect(store.load(hostId: "other", daemonId: "d1", sessionId: 7) == nil)
    }

    // MARK: Sealed at rest

    /// What an older app wrote: the plist in the clear, compressed.
    private func plainFile(_ workspace: CachedWorkspace) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try encoder.encode(workspace)
        return Data("UNWS".utf8) + (try (plist as NSData).compressed(using: .lzfse) as Data)
    }

    @Test func aSavedFileOpensOnlyWithThisDevicesKey() throws {
        let directory = temporaryDirectory()
        let secrets = MemorySecretStore()
        let store = WorkspaceCacheStore(directory: directory, secrets: secrets)
        let workspace = cached()
        try store.save(workspace)
        let raw = try Data(contentsOf: store.file(for: "h"))
        #expect(raw.starts(with: Data("UNWE".utf8) + [1]))
        #expect(try secrets.data(for: CacheSeal.keyName)?.count == 32)
        let reopened = WorkspaceCacheStore(directory: directory, secrets: secrets)
        #expect(reopened.load(hostId: "h", daemonId: "d1", sessionId: 7) == workspace)

        let otherDevice = WorkspaceCacheStore(directory: directory, secrets: MemorySecretStore())
        #expect(otherDevice.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.file(for: "h").path))
    }

    @Test func aTamperedFileIsDropped() throws {
        let store = WorkspaceCacheStore(directory: temporaryDirectory(), secrets: MemorySecretStore())
        try store.save(cached())
        let original = try Data(contentsOf: store.file(for: "h"))
        for offset in [4, 5, 20, original.count / 2, original.count - 1] {
            var tampered = original
            tampered[offset] ^= 0x01
            try tampered.write(to: store.file(for: "h"))
            #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil, "byte \(offset) changed")
            #expect(!FileManager.default.fileExists(atPath: store.file(for: "h").path))
        }
        try original.prefix(30).write(to: store.file(for: "h"))
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil, "cut short")

        // Another host's sealed file under this host's name.
        try store.save(cached(hostId: "other"))
        try FileManager.default.copyItem(at: store.file(for: "other"), to: store.file(for: "h"))
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil)
    }

    @Test func aPlainFileFromAnOlderAppIsSealedInPlace() throws {
        let store = WorkspaceCacheStore(directory: temporaryDirectory(), secrets: MemorySecretStore())
        let workspace = cached()
        try plainFile(workspace).write(to: store.file(for: "h"))

        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == workspace)
        let raw = try Data(contentsOf: store.file(for: "h"))
        #expect(raw.starts(with: Data("UNWE".utf8) + [1]))
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == workspace)

        // A stale one is deleted, never sealed.
        try plainFile(cached(daemonId: "d0")).write(to: store.file(for: "h"))
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.file(for: "h").path))
    }

    @Test func aLostKeyOnlyLosesTheCache() throws {
        let directory = temporaryDirectory()
        let secrets = MemorySecretStore()
        try WorkspaceCacheStore(directory: directory, secrets: secrets).save(cached())
        try secrets.remove(CacheSeal.keyName)

        let store = WorkspaceCacheStore(directory: directory, secrets: secrets)
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.file(for: "h").path))
        try store.save(cached())
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) != nil, "a new key seals the next save")

        try secrets.set(Data([1, 2, 3]), for: CacheSeal.keyName)
        let damagedKey = WorkspaceCacheStore(directory: directory, secrets: secrets)
        #expect(damagedKey.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil)
        try damagedKey.save(cached())
        #expect(damagedKey.load(hostId: "h", daemonId: "d1", sessionId: 7) != nil)
    }

    @Test func aKeychainThatRefusesTheKeyKeepsTheFileForLater() throws {
        let directory = temporaryDirectory()
        let secrets = MemorySecretStore()
        try WorkspaceCacheStore(directory: directory, secrets: secrets).save(cached())

        let locked = WorkspaceCacheStore(directory: directory, secrets: RefusingSecretStore())
        #expect(locked.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil)
        #expect(FileManager.default.fileExists(atPath: locked.file(for: "h").path))
        #expect(throws: SecretStoreError.self) { try locked.save(cached()) }

        #expect(WorkspaceCacheStore(directory: directory, secrets: secrets).load(hostId: "h", daemonId: "d1", sessionId: 7) != nil)
    }

    // MARK: A connection before and after the daemon answers

    private func connection(seeded: CachedWorkspace? = nil) throws -> (DaemonConnection, () -> FakeClient) {
        let client = Mutex<FakeClient?>(nil)
        let connection = DaemonConnection(hostId: "h", ticket: "t", session: 7) { _, listener in
            let fake = FakeClient(listener: listener)
            client.withLock { $0 = fake }
            return fake
        }
        if let seeded { connection.seed(seeded) }
        try connection.connect()
        return (connection, { client.withLock { $0! } })
    }

    @Test func aSeededConnectionShowsTheSavedWorkspaceThenTheHosts() async throws {
        let (connection, client) = try connection(seeded: cached())
        // At once, with nothing from the host: tabs, panes, names, projects.
        #expect(connection.showsCachedLayout)
        #expect(!connection.isReady)
        #expect(connection.layout.session.panes == [PaneId(1), PaneId(2), PaneId(3)])
        #expect(connection.meta[PaneId(1)]?.title == "make")
        #expect(connection.layout.projects.projects["p"]?.name == "api")
        #expect(connection.cachedScreen(for: PaneId(1))?.screen != nil)
        // Ops wait for the host (there is no session to send them to).
        connection.layout.apply(.newTab)
        #expect(!client().calls.contains { if case .op = $0 { true } else { false } })

        // The host closed pane 2 elsewhere: its layout wins, the saved pane and names go.
        client().send(.connected(epoch: 1, resumed: false))
        client().send(.attached(sessionId: 7, via: .requested, missing: nil))
        var layout = sampleLayout()
        layout.tabs[0].nodes = [.split(axis: .horizontal, ratio: 0.5, first: 1, second: 2), .leaf(paneId: 1), .leaf(paneId: 3)]
        client().send(.layout(layout: layout))
        try await eventually("live") { connection.isReady && connection.status.isLive }
        #expect(!connection.showsCachedLayout)
        #expect(connection.layout.session.panes == [PaneId(1), PaneId(3)])
        #expect(connection.meta[PaneId(2)] == nil)
        #expect(connection.cachedScreen(for: PaneId(2)) == nil)
    }

    @Test func hostGroupsListSavedTabsWhileConnecting() throws {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        let store = WorkspaceCacheStore(directory: temporaryDirectory(), secrets: MemorySecretStore())
        model.workspaceCache = store
        model.dialer = { _, listener in FakeClient(listener: listener) }
        var record = HostRecord(id: "h", name: "studio", kind: .daemon, daemonId: "d1")
        record.sessionId = 7
        model.upsert(record)
        try model.secrets.set("ticket", for: "host.h.ticket")
        try store.save(cached())

        let groups = HostGroups(hosts: model)
        try groups.open("h")
        let group = try #require(groups.group("h"))
        #expect(group.isCached)
        #expect(!group.isReady)
        #expect(group.tabs.map(\.id) == [TabId(10)])
        #expect(groups.tabs == [TabRef(hostId: "h", tab: TabId(10))])

        // Forgetting the host forgets what was saved of it.
        model.remove("h")
        #expect(store.load(hostId: "h", daemonId: "d1", sessionId: 7) == nil)
    }

    @Test func aGuestsViewOfAnotherHostIsNeverShownFromTheCache() throws {
        let model = HostsModel(secrets: MemorySecretStore(), repository: HostRepository(directory: temporaryDirectory()))
        let store = WorkspaceCacheStore(directory: temporaryDirectory(), secrets: MemorySecretStore())
        model.workspaceCache = store
        model.joinDialer = { _, listener in FakeClient(listener: listener) }
        var record = HostRecord(id: "h", name: "theirs", kind: .daemon, daemonId: "d1")
        record.sessionId = 7
        record.guest = true
        model.upsert(record)
        try model.secrets.set("invite", for: record.inviteKey)
        try store.save(cached())
        let connection = try #require(try model.open("h") as? DaemonConnection)
        #expect(!connection.showsCachedLayout)
        #expect(connection.layout.session.tabs.isEmpty)
    }

    // MARK: Input typed over a saved screen

    /// A pane started over a saved screen, as the app's `Pane` does: the saved screen restored
    /// into its terminal, input held, the stream started.
    private func heldPane(
        _ connection: DaemonConnection, saved: [String]
    ) throws -> (DaemonPaneBackend, Terminal, HeldStates) {
        let backend = try #require(try connection.makeBackend(for: PaneId(1)) as? DaemonPaneBackend)
        let screen = Terminal(cols: 80, rows: 24) { _ in }
        try screen.restore(snapshot: try #require(CachedPane(terminal: terminal(saved), title: "", cwd: nil).screen))
        let states = HeldStates()
        backend.holdInputUntilLive(screen: { screen.visibleText() }) { state in states.append(state) }
        backend.start { event in
            if case .snapshot(let data) = event { try? screen.restore(snapshot: data) }
        }
        return (backend, screen, states)
    }

    private func liveSnapshot(_ lines: [String]) throws -> Data {
        try #require(CachedPane(terminal: terminal(lines), title: "", cwd: nil).screen)
    }

    private func inputs(_ client: FakeClient) -> [String] {
        client.calls.compactMap { call in
            switch call {
            case .input(_, let data): String(decoding: data, as: UTF8.self)
            case .paste(_, let text): "paste:" + text
            default: nil
            }
        }
    }

    @Test func inputOverASavedScreenIsSentWhenTheHostShowsTheSameScreen() async throws {
        let (connection, client) = try connection(seeded: cached())
        let (backend, _, states) = try heldPane(connection, saved: ["$ "])
        Array("ls\r".utf8).withUnsafeBytes { backend.writeInput($0, inputSeq: 1) }
        backend.paste("more")
        #expect(inputs(client()).isEmpty, "nothing reaches the host before its screen is shown")
        #expect(states.all == [.holding(1), .holding(2)])

        client().send(.paneSnapshot(paneId: 1, seq: 0, data: try liveSnapshot(["$ "])))
        try await eventually("sent") { inputs(client()) == ["ls\r", "paste:more"] }
        #expect(states.all.last == .sent)

        // From then on input goes straight through.
        Array("x".utf8).withUnsafeBytes { backend.write($0) }
        #expect(inputs(client()).last == "x")
    }

    @Test func heldGeneratedReportsKeepTheirOrderAndSourceAmongTypedKeys() async throws {
        let (connection, client) = try connection(seeded: cached())
        let (backend, _, states) = try heldPane(connection, saved: ["$ "])
        Array("x".utf8).withUnsafeBytes { backend.write($0) }
        Array("\u{1b}[I".utf8).withUnsafeBytes { backend.writeGenerated($0) }
        Array("y".utf8).withUnsafeBytes { backend.write($0) }
        client().send(.paneSnapshot(paneId: 1, seq: 0, data: try liveSnapshot(["$ "])))
        try await eventually("held inputs sent") { states.all.last == .sent }
        let delivered = client().calls.filter {
            switch $0 {
            case .input, .generatedInput, .paste: true
            default: false
            }
        }
        #expect(delivered == [.input(1, Data("x".utf8)), .generatedInput(1, Data("\u{1b}[I".utf8)), .input(1, Data("y".utf8))])
    }

    @Test func tooMuchHeldGeneratedInputIsDropped() async throws {
        let (connection, client) = try connection(seeded: cached())
        let (backend, _, states) = try heldPane(connection, saved: ["$ "])
        [UInt8](repeating: 0, count: DaemonPaneBackend.holdBytes + 1).withUnsafeBytes { backend.writeGenerated($0) }
        client().send(.paneSnapshot(paneId: 1, seq: 0, data: try liveSnapshot(["$ "])))
        try await eventually("generated input dropped") { states.all.last == .dropped }
        #expect(!client().calls.contains { if case .generatedInput = $0 { true } else { false } })
    }

    @Test func inputOverASavedScreenIsDroppedWhenTheHostsScreenChanged() async throws {
        let (connection, client) = try connection(seeded: cached())
        let (backend, _, states) = try heldPane(connection, saved: ["Allow rm -rf build? (y/n)"])
        Array("y\r".utf8).withUnsafeBytes { backend.write($0) }
        client().send(.paneSnapshot(paneId: 1, seq: 0, data: try liveSnapshot(["Allow git push --force? (y/n)"])))
        try await eventually("dropped") { states.all.last == .dropped }
        #expect(inputs(client()).isEmpty, "never typed into a screen the user did not see")
    }

    @Test func tooMuchHeldInputIsDropped() async throws {
        let (connection, client) = try connection(seeded: cached())
        let (backend, _, states) = try heldPane(connection, saved: ["$ "])
        let text = String(repeating: "a", count: DaemonPaneBackend.holdBytes + 1)
        backend.paste(text)
        client().send(.paneSnapshot(paneId: 1, seq: 0, data: try liveSnapshot(["$ "])))
        try await eventually("dropped") { states.all.last == .dropped }
        #expect(inputs(client()).isEmpty)
    }

    @Test func aSecondWindowSeededFromASavedScreenStillHolds() async throws {
        let (connection, client) = try connection(seeded: cached())
        let (_, _, _) = try heldPane(connection, saved: ["$ "])
        // A second window's tap starts from the first one's terminal: still the saved screen.
        let (second, _, states) = try heldPane(connection, saved: ["$ "])
        Array("pwd\r".utf8).withUnsafeBytes { second.write($0) }
        #expect(inputs(client()).isEmpty)
        #expect(states.all == [.holding(1)])
        client().send(.paneSnapshot(paneId: 1, seq: 0, data: try liveSnapshot(["$ "])))
        try await eventually("sent") { inputs(client()) == ["pwd\r"] }
    }
}
