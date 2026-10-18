import Foundation
import PaneLayout
import Synchronization
import UnnamedCore

/// Delivers a connection's pane-stream events to pane backends on the Rust runtime thread
/// they arrive on, in order, without a hop through the main actor (the terminal is
/// thread-safe; input-to-echo latency matters). Output for a pane whose view has not started
/// yet is buffered (04-mobile-ux R12: output is buffered per session, independent of views).
nonisolated final class PaneRouter: Sendable {
    private struct Route {
        var sink: (@Sendable (PaneEvent) -> Void)?
        var pending: [PaneEvent] = []
        /// `seq` of the last snapshot, whose history `.history` events extend.
        var snapshotSeq: UInt64?
        /// Send times of inputs not acknowledged yet (FIFO; one ack per input).
        var unacked: [ContinuousClock.Instant] = []
        /// Send time of the oldest input not yet followed by output (keystroke-to-echo).
        var echoPending: ContinuousClock.Instant?
    }

    private let routes = Mutex<[UInt64: Route]>([:])
    /// The last connection state, replayed to panes that register later.
    private let connection = Mutex(PaneConnection.stale(reason: "Connecting…"))
    /// Keystroke-to-echo round trips (for the host's latency readout).
    let onEchoRoundTrip: @Sendable (Duration) -> Void

    init(onEchoRoundTrip: @escaping @Sendable (Duration) -> Void = { _ in }) {
        self.onEchoRoundTrip = onEchoRoundTrip
    }

    func register(_ pane: UInt64) {
        routes.withLock { routes in
            if routes[pane] == nil { routes[pane] = Route() }
        }
    }

    func start(_ pane: UInt64, sink: @escaping @Sendable (PaneEvent) -> Void) {
        let state = connection.withLock { $0 }
        let pending = routes.withLock { routes in
            var route = routes[pane] ?? Route()
            route.sink = sink
            let pending = route.pending
            route.pending = []
            routes[pane] = route
            return pending
        }
        sink(.connection(state))
        pending.forEach(sink)
    }

    func remove(_ pane: UInt64) {
        _ = routes.withLock { $0.removeValue(forKey: pane) }
    }

    var panes: [UInt64] { routes.withLock { Array($0.keys) } }

    func noteInput(_ pane: UInt64) {
        let now = ContinuousClock.now
        routes.withLock { routes in
            routes[pane]?.unacked.append(now)
            if routes[pane]?.echoPending == nil { routes[pane]?.echoPending = now }
        }
    }

    /// Routes one event from the connection. Returns true if it was a pane-stream event.
    @discardableResult
    func route(_ event: ClientEvent) -> Bool {
        switch event {
        case .paneBytes(let pane, _, let data):
            var echo: Duration?
            routes.withLock { routes in
                if let sent = routes[pane]?.echoPending {
                    echo = ContinuousClock.now - sent
                    routes[pane]?.echoPending = nil
                }
            }
            if let echo { onEchoRoundTrip(echo) }
            deliver(pane, .output(data))
        case .paneSnapshot(let pane, let seq, let data):
            routes.withLock { $0[pane]?.snapshotSeq = seq }
            deliver(pane, .snapshot(data))
        case .paneHistory(let pane, let snapshotSeq, let data, _, let done):
            let current = routes.withLock { $0[pane]?.snapshotSeq }
            guard current == snapshotSeq else { return true }
            deliver(pane, .history(data, done: done))
        case .paneResized(let pane, _, let size):
            deliver(pane, .resized(cols: size.cols, rows: size.rows))
        case .inputAck(let pane, _, let atSeq):
            let sent = routes.withLock { routes -> ContinuousClock.Instant? in
                guard routes[pane]?.unacked.isEmpty == false else { return nil }
                return routes[pane]?.unacked.removeFirst()
            }
            deliver(pane, .inputAck(atSeq: atSeq, rtt: sent.map { ContinuousClock.now - $0 }))
        case .echoHint(let hint):
            deliver(hint.paneId, .echo(EchoState(hint)))
        case .paneHistoryGone:
            break
        case .connected:
            broadcast(.live)
            return false
        case .disconnected(let reason), .refused(let reason):
            broadcast(.stale(reason: reason))
            return false
        default:
            return false
        }
        return true
    }

    /// Marks every pane live or stale (suspend, connection state).
    func broadcast(_ state: PaneConnection) {
        connection.withLock { $0 = state }
        let sinks = routes.withLock { routes in
            routes.keys.map { pane in
                // Unacknowledged input belongs to the old connection.
                routes[pane]?.unacked.removeAll()
                routes[pane]?.echoPending = nil
                return routes[pane]?.sink
            }
        }
        for sink in sinks.compactMap({ $0 }) { sink(.connection(state)) }
    }

    private func deliver(_ pane: UInt64, _ event: PaneEvent) {
        let sink = routes.withLock { routes -> (@Sendable (PaneEvent) -> Void)? in
            guard routes[pane] != nil else { return nil }
            if let sink = routes[pane]?.sink { return sink }
            routes[pane]?.pending.append(event)
            return nil
        }
        sink?(event)
    }
}

nonisolated extension EchoState {
    init(_ hint: EchoHint) {
        self.init(
            echo: hint.echo, canonical: hint.icanon, alternateScreen: hint.altScreen,
            atPrompt: hint.atPrompt, predict: hint.prediction == .allow, atSeq: hint.atSeq)
    }
}

/// A pane on a daemon. Output arrives through the connection's `PaneRouter`; input, paste,
/// resizes and history requests go to the `DaemonClient`. Closing the pane is a layout op
/// (the daemon ends the process), so `terminate` only stops following it.
nonisolated public final class DaemonPaneBackend: PaneBackend {
    public let pane: PaneId
    private let client: any DaemonClientAPI
    private let router: PaneRouter
    /// Bytes requested per history page.
    static let historyPageBytes: UInt32 = 256 * 1024

    init(pane: PaneId, client: any DaemonClientAPI, router: PaneRouter) {
        self.pane = pane
        self.client = client
        self.router = router
        router.register(pane.rawValue)
    }

    public func start(events: @escaping @Sendable (PaneEvent) -> Void) {
        router.start(pane.rawValue, sink: events)
        client.subscribe(paneId: pane.rawValue)
    }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        router.noteInput(pane.rawValue)
        client.sendInput(paneId: pane.rawValue, data: Data(bytes))
    }

    public func paste(_ text: String) {
        router.noteInput(pane.rawValue)
        client.sendPaste(paneId: pane.rawValue, text: text)
    }

    public func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        client.resize(
            paneId: pane.rawValue,
            size: PaneSize(
                cols: cols, rows: rows,
                widthPx: UInt16(clamping: UInt32(cols) * cellWidth),
                heightPx: UInt16(clamping: UInt32(rows) * cellHeight)))
    }

    public func requestHistory() -> Bool {
        client.fetchHistory(paneId: pane.rawValue, maxBytes: Self.historyPageBytes)
    }

    public func terminate() {
        client.unsubscribe(paneId: pane.rawValue)
        router.remove(pane.rawValue)
    }
}
