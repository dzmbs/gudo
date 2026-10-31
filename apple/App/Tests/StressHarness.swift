import Darwin
import Foundation
@testable import HostKit
import Synchronization
import UnnamedCore
@testable import App

/// The longest the main thread went without serving its queue, pinged every 5 ms from a
/// background thread: what a user sees as a hang.
nonisolated final class HangWatch: Sendable {
    struct Report: CustomStringConvertible {
        var worst: Duration = .zero
        var overBudget = 0
        var samples = 0
        var description: String { "worst \(worst.milliseconds) ms, \(overBudget) pings over 100 ms of \(samples)" }
    }

    private let state = Mutex<(running: Bool, report: Report)>((false, Report()))

    func start() {
        state.withLock { $0 = (true, Report()) }
        Thread.detachNewThread { [self] in
            while state.withLock({ $0.running }) {
                let sent = ContinuousClock.now
                let served = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { served.signal() }
                served.wait()
                let lag = ContinuousClock.now - sent
                state.withLock { state in
                    state.report.worst = max(state.report.worst, lag)
                    state.report.samples += 1
                    if lag > .milliseconds(100) { state.report.overBudget += 1 }
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func stop() -> Report {
        state.withLock { state in
            state.running = false
            return state.report
        }
    }
}

extension Duration {
    var milliseconds: Int { Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000) }
}

/// This process's footprint, CPU time and threads.
nonisolated enum ProcessStats {
    static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static var cpuSeconds: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static var threads: Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        return Int(count)
    }
}

/// A daemon host with many tabs, projects and agents, over the fake client, registered with
/// the app's hosts so windows list it like a paired daemon.
@MainActor
final class StressHost {
    let id: String
    let client = FakeWorkspaceClient()
    let connection: DaemonConnection
    let panes: [UInt64]
    let options = [DecisionOption(id: 1, label: "Yes"), DecisionOption(id: 2, label: "No")]

    init(id: String, tabs: Int, projects: Int, attention: Int = 0) throws {
        self.id = id
        let client = client
        client.state.withLock { $0.attention = AttentionList(items: (0..<UInt64(attention)).map { Self.attention($0, pane: $0 % UInt64(max(tabs, 1)) + 1) }, unseen: UInt32(attention)) }
        connection = DaemonConnection(hostId: id, ticket: "t") { _, listener in
            client.state.withLock { $0.events = listener }
            return client
        }
        panes = (1...UInt64(tabs)).map { $0 }
        try connection.connect()
        let hosts = AppModel.shared.hosts
        hosts.upsert(HostRecord(id: id, name: id, kind: .daemon, daemonId: id))
        hosts.connections[id] = connection
        client.send(.connected(epoch: 1, resumed: false))
        client.send(.attached(sessionId: 1, via: .requested, missing: nil))
        client.send(.layout(layout: SessionLayout(
            sessionId: 1, name: "main", revision: 1, activeTab: 1,
            tabs: panes.map { TabLayout(tabId: $0, name: "", nodes: [.leaf(paneId: $0)], focused: $0, zoomed: nil) })))
        if projects > 0 {
            let perProject = max(1, tabs / projects)
            client.send(.projects(projects: DaemonProjects(
                sessionId: 1, revision: 1,
                projects: (0..<projects).map { DaemonProject(id: "p\($0)", name: "project \($0)", color: UInt8($0 % 8), order: Int64($0), updatedMs: 0) },
                tabs: panes.map { DaemonTabProject(tabId: $0, projectId: "p\(min(Int($0 - 1) / perProject, projects - 1))", rank: Int64($0)) })))
        }
        for pane in panes { client.send(.paneMeta(meta: meta(pane, state: pane % 3 == 0 ? .running : .idle))) }
    }

    func meta(_ pane: UInt64, state: AgentState, title: String? = nil) -> PaneMeta {
        PaneMeta(
            paneId: pane, title: title ?? "task \(pane)", cwd: "/home/me/repo\(pane % 40)", exit: nil,
            agent: AgentStatus(kind: pane % 2 == 0 ? "claude" : "codex", state: state),
            size: PaneSize(cols: 80, rows: 24), sizePolicy: .smallest, sizedBy: nil)
    }

    /// The `n`-th status change: each pane cycles working → waiting → done.
    nonisolated func churn(_ n: Int) -> ClientEvent {
        let pane = UInt64(n % panes.count) + 1
        let state: AgentState = switch (n / panes.count) % 3 {
        case 0: .blocked(requestId: UInt64(n), summary: "rm -rf build/\(n)", options: options)
        case 1: .done
        default: .running
        }
        return .paneMeta(meta: PaneMeta(
            paneId: pane, title: "task \(pane) step \(n)", cwd: "/home/me/repo\(pane % 40)", exit: nil,
            agent: AgentStatus(kind: pane % 2 == 0 ? "claude" : "codex", state: state),
            size: PaneSize(cols: 80, rows: 24), sizePolicy: .smallest, sizedBy: nil))
    }

    nonisolated static func attention(_ id: UInt64, pane: UInt64) -> AttentionItem {
        AttentionItem(
            id: id, atMs: 1_700_000_000_000 + id * 1000, paneId: pane, sessionId: 1,
            kind: id % 2 == 0 ? .agentDone(agent: "claude") : .commandFinished(mark: CommandMark(
                paneId: pane, commandId: id, command: "cargo test \(id)", cwd: "/home/me/repo", startedAtMs: 0, atSeq: 0,
                finished: CommandEnd(exit: 0, durationMs: 12_000))),
            title: "item \(id)", body: "finished \(id)", seen: false, whileViewed: false)
    }

    /// Pushes an attention item as the daemon does.
    nonisolated func pushAttention(_ id: UInt64) {
        let item = Self.attention(id, pane: id % UInt64(panes.count) + 1)
        client.state.withLock { $0.listener }?.onWorkspaceEvent(event: .attention(update: .added(item: item, unseen: UInt32(id))))
    }

    func remove() {
        AppModel.shared.hosts.remove(id)
    }
}

/// Sends `count` events at `perSecond` from a background thread, as the core's runtime does.
nonisolated func drive(_ count: Int, perSecond: Double, _ send: @escaping @Sendable (Int) -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            let start = ContinuousClock.now
            for n in 0..<count {
                send(n)
                let due = start + .seconds(Double(n + 1) / perSecond)
                let now = ContinuousClock.now
                if due > now { Thread.sleep(forTimeInterval: Double((due - now).components.attoseconds) / 1e18 + Double((due - now).components.seconds)) }
            }
            done.resume()
        }
    }
}
