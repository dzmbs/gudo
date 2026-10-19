import Foundation
import PaneLayout
import Synchronization
import TerminalCore
import UnnamedCore

/// Delivers a connection's pane-stream events to pane backends on the Rust runtime thread
/// they arrive on, in order, without a hop through the main actor (the terminal is
/// thread-safe; input-to-echo latency matters). Output for a pane whose view has not started
/// yet is buffered (04-mobile-ux R12: output is buffered per session, independent of views).
///
/// It also turns the daemon's `EchoHint`/`InputAck` into the echo predictor's
/// `PredictionUpdate`s (`PredictionFeed`).
nonisolated final class PaneRouter: Sendable {
    private struct Route {
        var sink: (@Sendable (PaneEvent) -> Void)?
        var pending: [PaneEvent] = []
        /// The output offset each `pending` event brings the terminal to (in step with it).
        var pendingApplied: [Applied?] = []
        /// Told after the pane applied output up to an offset (drawing anchors, `onApplied`).
        var applied: (@Sendable (UInt64, Bool) -> Void)?
        /// The last output offset the sink applied (told to a late `onApplied`).
        var lastApplied: UInt64?
        var prediction: (@Sendable (PredictionUpdate) -> Void)?
        /// `seq` of the last snapshot, whose history `.history` events extend.
        var snapshotSeq: UInt64?
        /// Inputs not acknowledged yet, in send order (the daemon acks each input frame once):
        /// when it was sent and the predictor's sequence number for keystrokes.
        var unacked: [(sent: ContinuousClock.Instant, predicted: UInt64?)] = []
        /// An ack waiting for the output after `atSeq` to be delivered first.
        var pendingAck: (predicted: UInt64, atSeq: UInt64)?
        /// Send time of the oldest input not yet followed by output (keystroke-to-echo).
        var echoPending: ContinuousClock.Instant?
        var hint: TerminalCore.EchoHint?
        /// Smoothed input-to-ack round trip, seconds.
        var rtt: Double?
    }

    private let routes = Mutex<[UInt64: Route]>([:])
    /// The last connection state, replayed to panes that register later.
    private let connection = Mutex(PaneConnection.stale(reason: "Connecting…"))
    /// Set by `suspend`: the disconnect the suspension causes keeps the "Paused" reason.
    private let suspended = Mutex(false)
    /// Multiplayer: panes this connection may not type into (a viewer's role, another
    /// person's lease). Gated input is dropped here, never predicted, and reported.
    private let gate = Mutex(MultiplayerSession.InputGate.open)
    /// Called (on the input thread) when gated input was dropped.
    private let blocked = Mutex<(@Sendable (UInt64) -> Void)?>(nil)
    /// Keystroke-to-echo round trips (for the host's latency readout).
    let onEchoRoundTrip: @Sendable (Duration) -> Void
    /// How long an ack waits for the echo it implies before it is delivered anyway (input that
    /// prints nothing).
    static let ackGrace = DispatchTimeInterval.milliseconds(40)

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
        let (pending, offsets, applied) = routes.withLock { routes in
            var route = routes[pane] ?? Route()
            route.sink = sink
            let pending = (route.pending, route.pendingApplied, route.applied)
            route.pending = []
            route.pendingApplied = []
            routes[pane] = route
            return pending
        }
        sink(.connection(state))
        for (event, offset) in zip(pending, offsets) {
            sink(event)
            if let offset {
                routes.withLock { $0[pane]?.lastApplied = offset.seq }
                applied?(offset.seq, offset.snapshot)
            }
        }
    }

    func startPrediction(_ pane: UInt64, _ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void) {
        let (hint, rtt) = routes.withLock { routes in
            routes[pane]?.prediction = onUpdate
            return (routes[pane]?.hint, routes[pane]?.rtt)
        }
        if let rtt { onUpdate(.rtt(rtt)) }
        onUpdate(.hint(isGated(pane) ? nil : hint))
    }

    func remove(_ pane: UInt64) {
        _ = routes.withLock { $0.removeValue(forKey: pane) }
    }

    var panes: [UInt64] { routes.withLock { Array($0.keys) } }

    /// Whether raw input to a pane may be sent; reports the drop otherwise.
    func admitsInput(_ pane: UInt64) -> Bool {
        let gate = gate.withLock { $0 }
        guard gate.all || gate.panes.contains(pane) else { return true }
        blocked.withLock { $0 }?(pane)
        return false
    }

    /// Sets the multiplayer input gate. Gated panes get no echo prediction (nothing they type
    /// is sent, so nothing would ever be acknowledged).
    func setGate(_ new: MultiplayerSession.InputGate, onBlocked: (@Sendable (UInt64) -> Void)? = nil) {
        let old = gate.withLock { old in
            defer { old = new }
            return old
        }
        if let onBlocked { blocked.withLock { $0 = onBlocked } }
        guard old != new else { return }
        let targets = routes.withLock { routes in
            routes.map { pane, route in
                let gated = new.all || new.panes.contains(pane)
                return (route.prediction, gated ? nil : route.hint)
            }
        }
        for (prediction, hint) in targets { prediction?(.hint(hint)) }
    }

    private func isGated(_ pane: UInt64) -> Bool {
        gate.withLock { $0.all || $0.panes.contains(pane) }
    }

    /// Records an input frame about to be sent (`predicted`: the predictor's sequence number).
    func noteInput(_ pane: UInt64, predicted: UInt64? = nil) {
        let now = ContinuousClock.now
        routes.withLock { routes in
            routes[pane]?.unacked.append((now, predicted))
            if routes[pane]?.echoPending == nil { routes[pane]?.echoPending = now }
        }
    }

    /// Routes one event from the connection. Returns true if it was a pane-stream event.
    @discardableResult
    func route(_ event: ClientEvent) -> Bool {
        switch event {
        case .paneBytes(let pane, let seq, let data):
            var echo: Duration?
            routes.withLock { routes in
                if let sent = routes[pane]?.echoPending {
                    echo = ContinuousClock.now - sent
                    routes[pane]?.echoPending = nil
                }
            }
            if let echo { onEchoRoundTrip(echo) }
            deliver(pane, .output(data), applied: Applied(seq: seq + UInt64(data.count), snapshot: false))
            flushAck(pane, through: seq + UInt64(data.count))
        case .paneSnapshot(let pane, let seq, let data):
            routes.withLock { $0[pane]?.snapshotSeq = seq }
            deliver(pane, .snapshot(data), applied: Applied(seq: seq, snapshot: true))
            flushAck(pane, through: seq)
        case .paneHistory(let pane, let snapshotSeq, let data, _, let done):
            let current = routes.withLock { $0[pane]?.snapshotSeq }
            guard current == snapshotSeq else { return true }
            deliver(pane, .history(data, done: done))
        case .paneResized(let pane, _, let size):
            deliver(pane, .resized(cols: size.cols, rows: size.rows))
        case .inputAck(let pane, _, let atSeq):
            acknowledge(pane, atSeq: atSeq)
        case .echoHint(let hint):
            let mapped = TerminalCore.EchoHint(
                echo: hint.echo, canonical: hint.icanon, atPrompt: hint.atPrompt, altScreen: hint.altScreen)
            let feed = routes.withLock { routes -> (@Sendable (PredictionUpdate) -> Void)? in
                routes[hint.paneId]?.hint = mapped
                return routes[hint.paneId]?.prediction
            }
            feed?(.hint(isGated(hint.paneId) ? nil : mapped))
        case .paneHistoryGone:
            break
        case .connected:
            suspended.withLock { $0 = false }
            broadcast(.live)
            return false
        case .disconnected(let reason), .refused(let reason):
            if !suspended.withLock({ $0 }) { broadcast(.stale(reason: reason)) }
            return false
        default:
            return false
        }
        return true
    }

    /// The app suspended the connection (iOS background): panes show "Paused" until it is back.
    func suspend() {
        suspended.withLock { $0 = true }
        broadcast(.stale(reason: "Paused"))
    }

    /// Marks every pane live or stale (suspend, connection state). While stale nothing is
    /// predicted; inputs in flight belong to the old connection.
    func broadcast(_ state: PaneConnection) {
        connection.withLock { $0 = state }
        let targets = routes.withLock { routes in
            routes.keys.map { pane in
                routes[pane]?.unacked.removeAll()
                routes[pane]?.pendingAck = nil
                routes[pane]?.echoPending = nil
                return (routes[pane]?.sink, routes[pane]?.prediction, isGated(pane) ? nil : routes[pane]?.hint)
            }
        }
        for (sink, prediction, hint) in targets {
            sink?(.connection(state))
            prediction?(.hint(state == .live ? hint : nil))
        }
    }

    private func acknowledge(_ pane: UInt64, atSeq: UInt64) {
        let now = ContinuousClock.now
        let (feed, rtt, predicted) = routes.withLock { routes -> ((@Sendable (PredictionUpdate) -> Void)?, Double?, UInt64?) in
            guard var route = routes[pane], !route.unacked.isEmpty else { return (nil, nil, nil) }
            let (sent, predicted) = route.unacked.removeFirst()
            let sample = (now - sent) / .seconds(1)
            route.rtt = route.rtt.map { 0.8 * $0 + 0.2 * sample } ?? sample
            if let predicted { route.pendingAck = (predicted, atSeq) }
            routes[pane] = route
            return (route.prediction, route.rtt, predicted)
        }
        if let rtt { feed?(.rtt(rtt)) }
        // The echo of this input comes after `atSeq`; ack once it has been delivered, or after a
        // short grace if the input printed nothing.
        if predicted != nil {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Self.ackGrace) { [self] in
                flushAck(pane, through: nil)
            }
        }
    }

    /// Delivers a pending ack once output past its `atSeq` went out (`through`), or
    /// unconditionally (`nil`, the grace timer).
    private func flushAck(_ pane: UInt64, through: UInt64?) {
        let update = routes.withLock { routes -> (feed: (@Sendable (PredictionUpdate) -> Void)?, update: PredictionUpdate)? in
            guard let ack = routes[pane]?.pendingAck else { return nil }
            if let through, through <= ack.atSeq { return nil }
            routes[pane]?.pendingAck = nil
            return (routes[pane]?.prediction, .acknowledged(upTo: ack.predicted, hint: routes[pane]?.hint))
        }
        if let update { update.feed?(update.update) }
    }

    /// An output offset the pane's terminal reaches with an event.
    struct Applied: Sendable {
        var seq: UInt64
        var snapshot: Bool
    }

    /// `callback` runs after the pane's sink applied output up to an offset (`snapshot`: a
    /// snapshot taken there replaced the terminal), on the delivering thread, in order.
    /// Output the sink applied before the callback was set is reported once, at once, as a
    /// snapshot at the last offset (the terminal's state there; nothing earlier is known).
    func onApplied(_ pane: UInt64, _ callback: (@Sendable (UInt64, Bool) -> Void)?) {
        let last = routes.withLock { routes in
            if routes[pane] == nil { routes[pane] = Route() }
            routes[pane]?.applied = callback
            return routes[pane]?.lastApplied
        }
        if let last { callback?(last, true) }
    }

    private func deliver(_ pane: UInt64, _ event: PaneEvent, applied offset: Applied? = nil) {
        let target = routes.withLock { routes -> (sink: (@Sendable (PaneEvent) -> Void), applied: (@Sendable (UInt64, Bool) -> Void)?)? in
            guard routes[pane] != nil else { return nil }
            if let sink = routes[pane]?.sink { return (sink, routes[pane]?.applied) }
            routes[pane]?.pending.append(event)
            routes[pane]?.pendingApplied.append(offset)
            return nil
        }
        guard let target else { return }
        target.sink(event)
        if let offset {
            routes.withLock { $0[pane]?.lastApplied = offset.seq }
            target.applied?(offset.seq, offset.snapshot)
        }
    }
}

/// A pane on a daemon. Output arrives through the connection's `PaneRouter`; input, paste,
/// resizes and history requests go to the `DaemonClient`. Closing the pane is a layout op
/// (the daemon ends the process), so `terminate` only stops following it.
nonisolated public final class DaemonPaneBackend: PredictionFeed {
    public let pane: PaneId
    /// The daemon reports every PTY resize in the stream (`PaneResized`).
    public var sizeFollowsStream: Bool { true }
    let client: any DaemonClientAPI
    let router: PaneRouter
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

    public func startPredictionFeed(_ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void) {
        router.startPrediction(pane.rawValue, onUpdate)
    }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, router.admitsInput(pane.rawValue) else { return }
        router.noteInput(pane.rawValue)
        client.sendInput(paneId: pane.rawValue, data: Data(bytes))
    }

    public func writeInput(_ bytes: UnsafeRawBufferPointer, inputSeq: UInt64) {
        guard !bytes.isEmpty, router.admitsInput(pane.rawValue) else { return }
        router.noteInput(pane.rawValue, predicted: inputSeq)
        client.sendInput(paneId: pane.rawValue, data: Data(bytes))
    }

    public func paste(_ text: String) {
        guard router.admitsInput(pane.rawValue) else { return }
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
