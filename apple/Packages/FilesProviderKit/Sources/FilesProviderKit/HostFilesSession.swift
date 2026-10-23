import FileProvider
import Foundation
import HostKit
import Synchronization
import UnnamedCore

/// One host's connection for the extension: dialled on first use, folders listed lately
/// watched on the host, and a sync anchor that moves whenever something may have changed
/// there (a watched folder, a reconnect: watches end with a connection). Files then asks the
/// working set again (`signal`).
nonisolated public final class HostFilesSession: Sendable {
    private struct State {
        var client: DaemonClient?
        var core: FilesProviderCore?
        var watched: [String: UInt64] = [:]
        var generation: UInt64 = 0
        var isUp = false
        var connectedOnce = false
    }

    private let share: FilesShare
    private let hostId: String
    private let relayBase: RelayMode
    private let signal: @Sendable () -> Void
    private let state = Mutex(State())
    /// Anchors from another process of the extension are always stale.
    private let launch = UUID()

    /// - Parameter signal: something on the host may have changed (signal the working set).
    public init(share: FilesShare, hostId: String, relayBase: RelayMode = .default, signal: @escaping @Sendable () -> Void) {
        self.share = share
        self.hostId = hostId
        self.relayBase = relayBase
        self.signal = signal
    }

    public func core() throws -> FilesProviderCore {
        if let core = state.withLock({ $0.core }) { return core }
        // Dialled outside the lock: connection events take it from the core's runtime.
        let listener = SessionListener(session: self)
        let client = try share.connect(hostId: hostId, listener: listener, relayBase: relayBase)
        client.setWorkspaceListener(listener: listener)
        let core = FilesProviderCore(
            remote: client, identifiers: share.identifiers(for: hostId),
            downloads: share.hostDirectory(hostId).appending(path: "downloads"),
            onContainerChanged: { [weak self] _ in self?.changed() })
        let (winner, extra) = state.withLock { state -> (FilesProviderCore, DaemonClient?) in
            if let existing = state.core { return (existing, client) }
            state.client = client
            state.core = core
            return (core, nil)
        }
        extra?.suspend()
        return winner
    }

    // MARK: Sync anchor

    public var anchor: NSFileProviderSyncAnchor {
        let generation = state.withLock { $0.generation }
        return NSFileProviderSyncAnchor(Data("\(launch.uuidString)/\(generation)".utf8))
    }

    /// Whether anything may have changed since `anchor` was handed out.
    public func isCurrent(_ anchor: NSFileProviderSyncAnchor) -> Bool {
        anchor == self.anchor
    }

    func changed() {
        state.withLock { $0.generation += 1 }
        signal()
    }

    // MARK: Watches

    /// Watches what the working set follows (at most its folders, the oldest dropped).
    public func watchVisited() async {
        guard let core = try? core(), let client = state.withLock({ $0.client }) else { return }
        let wanted = Set(core.identifiers.visitedDirectories)
        let (stale, missing) = state.withLock { state in
            (state.watched.filter { !wanted.contains($0.key) }, wanted.filter { state.watched[$0] == nil })
        }
        for (path, id) in stale {
            try? await client.fsUnwatch(watchId: id)
            state.withLock { _ = $0.watched.removeValue(forKey: path) }
        }
        for path in missing {
            guard let id = try? await client.fsWatch(path: path) else { continue }
            state.withLock { $0.watched[path] = id }
        }
    }

    fileprivate func connection(up: Bool) {
        let reconnected = state.withLock { state in
            defer {
                state.isUp = up
                state.connectedOnce = state.connectedOnce || up
            }
            if !up { state.watched = [:] }
            return up && !state.isUp && state.connectedOnce
        }
        if reconnected {
            changed()
            Task { await watchVisited() }
        }
    }

    public func close() {
        let client = state.withLock { state in
            defer { state = State() }
            return state.client
        }
        client?.suspend()
    }
}

nonisolated private final class SessionListener: ClientEventListener, WorkspaceListener {
    weak let session: HostFilesSession?

    init(session: HostFilesSession) {
        self.session = session
    }

    func onEvent(event: ClientEvent) {
        switch event {
        case .connected: session?.connection(up: true)
        case .disconnected: session?.connection(up: false)
        default: break
        }
    }

    func onWorkspaceEvent(event: WorkspaceEvent) {
        if case .fsChanged = event { session?.changed() }
    }
}
