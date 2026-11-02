import Foundation
import HostKit
import os
import PaneLayout
import TerminalCore

/// Saves each daemon host's workspace for instant start: a moment after its layout, names or projects change, every half minute while its screens
/// change, and at once when the app goes to the background or quits. Only hosts that are
/// live and owned: never a saved screen written back, never a guest's view of someone else's
/// host.
@MainActor
final class WorkspaceCacheWriter {
    let store: WorkspaceCacheStore
    private let hosts: HostsModel
    /// Every window's workspaces (their panes hold the terminals).
    private let workspaces: () -> [Workspace]
    private var pending: Task<Void, Never>?
    /// What each host's last save was made from, to skip saves that would change nothing.
    private var saved: [String: Basis] = [:]

    private struct Basis: Equatable {
        var session: Session
        var projects: HostProjects
        var titles: [PaneId: String]
        var outputs: Int
    }

    static let debounce = Duration.seconds(2)
    static let interval = Duration.seconds(30)
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "cache")

    init(store: WorkspaceCacheStore, hosts: HostsModel, workspaces: @escaping () -> [Workspace]) {
        self.store = store
        self.hosts = hosts
        self.workspaces = workspaces
    }

    func start() {
        observe()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.interval)
                guard let self else { return }
                saveChanged(screens: true)
            }
        }
    }

    /// The app is leaving (background, quit): everything that changed, now, on this thread.
    func flush() {
        pending?.cancel()
        pending = nil
        for (id, work) in drafts(screens: true) {
            do {
                try store.save(work.draft.capturingScreens(work.terminals, limits: store.limits))
                saved[id] = work.basis
            } catch {
                Self.log.error("saving workspace host=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Layouts, names, projects and statuses of every daemon host: a change saves soon.
    private func observe() {
        withObservationTracking {
            for case let daemon as DaemonConnection in hosts.connections.values {
                _ = daemon.layout.session
                _ = daemon.layout.projects
                _ = daemon.meta
                _ = daemon.status
            }
        } onChange: {
            Task { @MainActor [weak self] in
                self?.schedule()
                self?.observe()
            }
        }
    }

    private func schedule() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            saveChanged(screens: false)
        }
    }

    /// Saves hosts whose layout or names changed (and, with `screens`, whose screens did),
    /// encoding the screens off the main actor.
    private func saveChanged(screens: Bool) {
        let store = store
        for (id, work) in drafts(screens: screens) {
            saved[id] = work.basis
            Task.detached(priority: .utility) {
                do {
                    try store.save(work.draft.capturingScreens(work.terminals, limits: store.limits))
                } catch {
                    Self.log.error("saving workspace host=\(id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private struct Work {
        var draft: CachedWorkspace
        var terminals: [UInt64: Terminal]
        var basis: Basis
    }

    /// What to save per host that changed since its last save.
    private func drafts(screens: Bool) -> [String: Work] {
        var result: [String: Work] = [:]
        let open = workspaces()
        for (id, connection) in hosts.connections {
            guard let daemon = connection as? DaemonConnection, daemon.status.isLive,
                  let record = hosts.record(id), record.kind == .daemon, !record.isGuest,
                  let draft = daemon.workspaceToSave(daemonId: record.daemonId)
            else { continue }
            let shown = open.filter { $0.hostId == id }
            // Still showing what was saved: nothing newer to keep yet.
            if shown.contains(where: { $0.panes.values.contains(where: \.showsSavedScreen) }) { continue }
            var terminals: [UInt64: Terminal] = [:]
            var outputs = 0
            for workspace in shown {
                for (paneId, pane) in workspace.panes where terminals[paneId.rawValue] == nil {
                    terminals[paneId.rawValue] = pane.view.surface.terminal
                    outputs += pane.outputGeneration.withLock { $0 }
                }
            }
            let basis = Basis(
                session: draft.session, projects: draft.projects,
                titles: draft.panes.reduce(into: [:]) { $0[PaneId($1.key)] = $1.value.title }, outputs: outputs)
            if let last = saved[id] {
                var unchanged = last
                if !screens { unchanged.outputs = basis.outputs }
                if unchanged == basis { continue }
            }
            result[id] = Work(draft: draft, terminals: terminals, basis: basis)
        }
        return result
    }
}
