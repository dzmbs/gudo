import Foundation
import PaneLayout
import Synchronization
import TerminalCore
import GudoCore

/// Delivers a connection's pane-stream events to pane backends on the Rust runtime thread
/// they arrive on, in order, without a hop through the main actor (the terminal is
/// thread-safe; input-to-echo latency matters). Output for a pane whose view has not started
/// yet is buffered: output is buffered per session, independent of views.
///
/// A pane shown in several windows has one stream (the daemon keeps one subscription per pane
/// per connection) and one tap per window (`DaemonPaneBackend`): every tap's terminal gets every
/// event, in the same order. A tap that starts while others run is seeded from one of their
/// terminals (`SharedPaneTap.start(events:seed:)`), so it shows the same screen and scrollback
/// without asking the daemon again. The connection has one size per pane, so only the tap that
/// drives (typed or took focus last) sends its size.
///
/// It also turns the daemon's `EchoHint`/`InputAck` into the echo predictor's
/// `PredictionUpdate`s (`PredictionFeed`); an ack goes to the tap whose keystroke it answers.
nonisolated final class PaneRouter: Sendable {
    typealias Sink = @Sendable (PaneEvent) -> Void
    typealias Applied = @Sendable (UInt64, Bool) -> Void
    typealias Prediction = @Sendable (PredictionUpdate) -> Void
    typealias Seed = @Sendable () -> [PaneEvent]

    private struct Tap {
        var sink: Sink?
        /// How to copy this tap's terminal for a tap that starts later.
        var seed: Seed?
        /// Told after the tap's terminal applied output up to an offset (drawing anchors,
        /// command marks), by observer name.
        var applied: [String: Applied] = [:]
        var prediction: Prediction?
        /// The size this tap's window wants (sent while it drives).
        var size: PaneSize?
    }

    private struct Route {
        var taps: [UInt64: Tap] = [:]
        /// The tap whose size the pane has (the last to type or take focus).
        var driver: UInt64?
        var pending: [PaneEvent] = []
        /// The output offset each `pending` event brings the terminal to (in step with it).
        var pendingApplied: [Offset?] = []
        /// The last output offset the taps applied (told to a late `onApplied`).
        var lastApplied: UInt64?
        /// `seq` of the last snapshot, whose history `.history` events extend.
        var snapshotSeq: UInt64?
        /// The daemon sent this pane's state (a snapshot or bytes) on this connection: the taps
        /// show the host's screen, not a saved one.
        var live = false
        /// Inputs not acknowledged yet, in send order (the daemon acks each input frame once):
        /// when it was sent, the predictor's sequence number for keystrokes, and whose it was.
        var unacked: [(sent: ContinuousClock.Instant, predicted: UInt64?, tap: UInt64)] = []
        /// An ack waiting for the output after `atSeq` to be delivered first.
        var pendingAck: (predicted: UInt64, atSeq: UInt64, tap: UInt64)?
        /// Send time of the oldest input not yet followed by output (keystroke-to-echo).
        var echoPending: ContinuousClock.Instant?
        var hint: TerminalCore.EchoHint?
        /// Smoothed input-to-ack round trip, seconds.
        var rtt: Double?

        var started: [(id: UInt64, sink: Sink)] {
            taps.sorted { $0.key < $1.key }.compactMap { id, tap in tap.sink.map { (id, $0) } }
        }
    }

    private let routes = Mutex<[UInt64: Route]>([:])
    /// Held while events are handed to taps and while a tap is seeded, so a seed is exactly the
    /// state before the next event (never taken in the middle of one, never missing one).
    /// Order: `delivery`, then `routes`, never the reverse.
    private let delivery = Mutex(())
    private let nextTap = Atomic<UInt64>(1)
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
    /// Input went unacknowledged for `stallAfter` (the link may be dead while it looks up).
    let onInputStalled: @Sendable () -> Void
    /// How long the oldest input may wait for the daemon's ack before the link is checked.
    static let stallAfter = DispatchTimeInterval.seconds(1)
    /// How long an ack waits for the echo it implies before it is delivered anyway (input that
    /// prints nothing).
    static let ackGrace = DispatchTimeInterval.milliseconds(40)

    init(
        onEchoRoundTrip: @escaping @Sendable (Duration) -> Void = { _ in },
        onInputStalled: @escaping @Sendable () -> Void = {}
    ) {
        self.onEchoRoundTrip = onEchoRoundTrip
        self.onInputStalled = onInputStalled
    }

    /// A new tap on `pane` (output buffers from now on, until a tap starts). Returns its id.
    func register(_ pane: UInt64) -> UInt64 {
        let id = nextTap.wrappingAdd(1, ordering: .relaxed).oldValue
        routes.withLock { routes in
            routes[pane, default: Route()].taps[id] = Tap()
        }
        return id
    }

    /// Starts delivering to a tap. The first tap gets the buffered stream; a later one starts
    /// from another tap's terminal (`seed` of the others), then follows the stream. Returns
    /// whether this is the pane's first running tap (the caller subscribes then).
    @discardableResult
    func start(_ pane: UInt64, tap id: UInt64, sink: @escaping Sink, seed: Seed? = nil) -> Bool {
        delivery.withLock { _ in
            let state = connection.withLock { $0 }
            let (first, source, pending, offsets, lastApplied) = routes.withLock { routes in
                var route = routes[pane] ?? Route()
                let running = route.started
                let source = route.driver.flatMap { route.taps[$0]?.sink != nil ? route.taps[$0]?.seed : nil }
                    ?? running.lazy.compactMap { route.taps[$0.id]?.seed }.first
                var tap = route.taps[id] ?? Tap()
                tap.sink = sink
                tap.seed = seed
                route.taps[id] = tap
                let (pendingEvents, pendingOffsets) = (route.pending, route.pendingApplied)
                if running.isEmpty {
                    route.pending = []
                    route.pendingApplied = []
                }
                routes[pane] = route
                return (running.isEmpty, source, pendingEvents, pendingOffsets, route.lastApplied)
            }
            sink(.connection(state))
            if first {
                for (event, offset) in zip(pending, offsets) {
                    sink(event)
                    if let offset { applied(pane, offset, only: id) }
                }
            } else if let source {
                for event in source() { sink(event) }
                if let lastApplied { applied(pane, Offset(seq: lastApplied, snapshot: true), only: id) }
            }
            return first
        }
    }

    func startPrediction(_ pane: UInt64, tap id: UInt64, _ onUpdate: @escaping Prediction) {
        let (hint, rtt) = routes.withLock { routes in
            routes[pane]?.taps[id]?.prediction = onUpdate
            return (routes[pane]?.hint, routes[pane]?.rtt)
        }
        if let rtt { onUpdate(.rtt(rtt)) }
        onUpdate(.hint(isGated(pane) ? nil : hint))
    }

    /// Removes a tap. `last`: it was the pane's last (the caller unsubscribes then);
    /// `handover`: the size of the tap that drives now (the caller sends it).
    @discardableResult
    func remove(_ pane: UInt64, tap id: UInt64) -> (last: Bool, handover: PaneSize?) {
        routes.withLock { routes in
            guard var route = routes[pane] else { return (false, nil) }
            route.taps[id] = nil
            var handover: PaneSize?
            if route.driver == id {
                // The window that drove closed: the oldest window still showing the pane drives.
                let next = route.taps.filter { $0.value.size != nil }.min { $0.key < $1.key }
                route.driver = next?.key
                handover = next?.value.size
            }
            route.unacked.removeAll { $0.tap == id }
            if route.pendingAck?.tap == id { route.pendingAck = nil }
            if route.taps.isEmpty {
                routes[pane] = nil
                return (true, nil)
            }
            routes[pane] = route
            return (false, handover)
        }
    }

    var panes: [UInt64] { routes.withLock { Array($0.keys) } }

    /// Whether the daemon has sent the pane's state (see `Route.live`).
    func isLive(_ pane: UInt64) -> Bool { routes.withLock { $0[pane]?.live ?? false } }

    /// Running taps of a pane (tests, diagnostics).
    func tapCount(_ pane: UInt64) -> Int { routes.withLock { $0[pane]?.taps.count ?? 0 } }

    // MARK: Size

    /// A tap's window wants `size`. Returns the size to send: this one if the tap drives (or
    /// nothing drives yet), else nil (the driving window keeps the pane's size).
    func resize(_ pane: UInt64, tap id: UInt64, to size: PaneSize) -> PaneSize? {
        routes.withLock { routes in
            routes[pane]?.taps[id]?.size = size
            guard let route = routes[pane] else { return nil }
            if route.driver == nil { routes[pane]?.driver = id }
            return route.driver == nil || route.driver == id ? size : nil
        }
    }

    /// A tap types or takes focus: it drives the pane's size from now on. Returns its size when
    /// that changes the pane's (to send before the input).
    func claim(_ pane: UInt64, tap id: UInt64) -> PaneSize? {
        routes.withLock { routes in
            guard let route = routes[pane], route.driver != id else { return nil }
            routes[pane]?.driver = id
            // The first tap ever claiming has already sent its size.
            return route.driver == nil ? nil : route.taps[id]?.size
        }
    }

    // MARK: Input

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
            routes.flatMap { pane, route in
                let gated = new.all || new.panes.contains(pane)
                return route.taps.values.map { ($0.prediction, gated ? nil : route.hint) }
            }
        }
        for (prediction, hint) in targets { prediction?(.hint(hint)) }
    }

    private func isGated(_ pane: UInt64) -> Bool {
        gate.withLock { $0.all || $0.panes.contains(pane) }
    }

    /// Records an input frame about to be sent (`predicted`: the predictor's sequence number).
    func noteInput(_ pane: UInt64, tap id: UInt64, predicted: UInt64? = nil) {
        let now = ContinuousClock.now
        let first = routes.withLock { routes in
            routes[pane]?.unacked.append((now, predicted, id))
            if routes[pane]?.echoPending == nil { routes[pane]?.echoPending = now }
            return routes[pane]?.unacked.count == 1
        }
        guard first else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.stallAfter) { [self] in
            let stalled = routes.withLock { $0[pane]?.unacked.first?.sent == now }
            if stalled { onInputStalled() }
        }
    }

    // MARK: Events

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
            routes.withLock { $0[pane]?.live = true }
            deliver(pane, .output(data), applied: Offset(seq: seq + UInt64(data.count), snapshot: false))
            flushAck(pane, through: seq + UInt64(data.count))
        case .paneSnapshot(let pane, let seq, let data):
            routes.withLock {
                $0[pane]?.snapshotSeq = seq
                $0[pane]?.live = true
            }
            deliver(pane, .snapshot(data), applied: Offset(seq: seq, snapshot: true))
            flushAck(pane, through: seq)
        case .paneHistory(let pane, let snapshotSeq, let data, _, let done):
            let current = routes.withLock { $0[pane]?.snapshotSeq }
            guard current == snapshotSeq else { return true }
            deliver(pane, .history(data, done: done))
        case .paneResized(let pane, _, let size):
            deliver(pane, .resized(size))
        case .inputAck(let pane, _, let atSeq):
            acknowledge(pane, atSeq: atSeq)
        case .echoHint(let hint):
            let mapped = TerminalCore.EchoHint(
                echo: hint.echo, canonical: hint.icanon, atPrompt: hint.atPrompt, altScreen: hint.altScreen)
            let feeds = routes.withLock { routes -> [Prediction] in
                routes[hint.paneId]?.hint = mapped
                return routes[hint.paneId]?.taps.values.compactMap(\.prediction) ?? []
            }
            let gated = isGated(hint.paneId)
            for feed in feeds { feed(.hint(gated ? nil : mapped)) }
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
        delivery.withLock { _ in
            connection.withLock { $0 = state }
            let targets = routes.withLock { routes in
                routes.keys.flatMap { pane in
                    routes[pane]?.unacked.removeAll()
                    routes[pane]?.pendingAck = nil
                    routes[pane]?.echoPending = nil
                    let hint = isGated(pane) ? nil : routes[pane]?.hint
                    return routes[pane]?.taps.values.map { ($0.sink, $0.prediction, hint) } ?? []
                }
            }
            for (sink, prediction, hint) in targets {
                sink?(.connection(state))
                prediction?(.hint(state == .live ? hint : nil))
            }
        }
    }

    private func acknowledge(_ pane: UInt64, atSeq: UInt64) {
        let now = ContinuousClock.now
        let (feeds, rtt, predicted) = routes.withLock { routes -> ([Prediction], Double?, UInt64?) in
            guard var route = routes[pane], !route.unacked.isEmpty else { return ([], nil, nil) }
            let (sent, predicted, tap) = route.unacked.removeFirst()
            let sample = (now - sent) / .seconds(1)
            route.rtt = route.rtt.map { 0.8 * $0 + 0.2 * sample } ?? sample
            if let predicted { route.pendingAck = (predicted, atSeq, tap) }
            routes[pane] = route
            return (route.taps.values.compactMap(\.prediction), route.rtt, predicted)
        }
        if let rtt { for feed in feeds { feed(.rtt(rtt)) } }
        // The echo of this input comes after `atSeq`; ack once it has been delivered, or after a
        // short grace if the input printed nothing.
        if predicted != nil {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Self.ackGrace) { [self] in
                flushAck(pane, through: nil)
            }
        }
    }

    /// Delivers a pending ack once output past its `atSeq` went out (`through`), or
    /// unconditionally (`nil`, the grace timer). It goes to the tap that sent the input.
    private func flushAck(_ pane: UInt64, through: UInt64?) {
        let update = routes.withLock { routes -> (feed: Prediction?, update: PredictionUpdate)? in
            guard let ack = routes[pane]?.pendingAck else { return nil }
            if let through, through <= ack.atSeq { return nil }
            routes[pane]?.pendingAck = nil
            return (routes[pane]?.taps[ack.tap]?.prediction, .acknowledged(upTo: ack.predicted, hint: routes[pane]?.hint))
        }
        if let update { update.feed?(update.update) }
    }

    /// An output offset the pane's terminal reaches with an event.
    struct Offset: Sendable {
        var seq: UInt64
        var snapshot: Bool
    }

    /// `callback` runs after a tap's terminal applied output up to an offset (`snapshot`: a
    /// snapshot taken there replaced the terminal), on the delivering thread, in order.
    /// Output applied before the callback was set is reported once, at once, as a snapshot at
    /// the last offset (the terminal's state there; nothing earlier is known).
    /// Each `observer` name has one callback; nil removes it.
    func onApplied(_ pane: UInt64, tap id: UInt64, observer: String, _ callback: Applied?) {
        let last = routes.withLock { routes in
            routes[pane]?.taps[id]?.applied[observer] = callback
            return routes[pane]?.lastApplied
        }
        if let last { callback?(last, true) }
    }

    /// Tells the taps (or one) that their terminals reached `offset`.
    private func applied(_ pane: UInt64, _ offset: Offset, only: UInt64? = nil) {
        let callbacks = routes.withLock { routes -> [Applied] in
            routes[pane]?.lastApplied = offset.seq
            guard let taps = routes[pane]?.taps else { return [] }
            if let only { return taps[only].map { Array($0.applied.values) } ?? [] }
            return taps.values.flatMap(\.applied.values)
        }
        for callback in callbacks { callback(offset.seq, offset.snapshot) }
    }

    private func deliver(_ pane: UInt64, _ event: PaneEvent, applied offset: Offset? = nil) {
        delivery.withLock { _ in
            let sinks = routes.withLock { routes -> [Sink]? in
                guard let route = routes[pane] else { return nil }
                let sinks = route.started.map(\.sink)
                if sinks.isEmpty {
                    routes[pane]?.pending.append(event)
                    routes[pane]?.pendingApplied.append(offset)
                }
                return sinks
            }
            guard let sinks, !sinks.isEmpty else { return }
            for sink in sinks { sink(event) }
            if let offset { applied(pane, offset) }
        }
    }
}

/// A pane on a daemon. Output arrives through the connection's `PaneRouter`; input, paste,
/// resizes and history requests go to the `DaemonClient`. Closing the pane is a layout op
/// (the daemon ends the process), so `terminate` only stops following it.
///
/// Each window showing the pane has its own instance (a tap of the router): the connection
/// subscribes once, when the first starts, and unsubscribes when the last ends.
nonisolated public final class DaemonPaneBackend: PredictionFeed, SharedPaneTap {
    public let pane: PaneId
    /// The daemon reports every PTY resize in the stream (`PaneResized`).
    public var sizeFollowsStream: Bool { true }
    /// The daemon's VT answers queries (docs/DAEMON.md "Threading model").
    public var hostAnswersQueries: Bool { true }
    /// The host's, as its connection reported it before any snapshot (docs/DAEMON.md §7.10).
    public var kittyImageStorageLimit: UInt64? { (client as? any TerminalLimitsClient)?.imageStorageLimit() }
    let client: any DaemonClientAPI
    let router: PaneRouter
    /// This window's tap on the pane's stream.
    let tap: UInt64
    /// Input typed while the pane shows a saved screen (instant start), until the host's.
    private let held = Mutex<HeldInput?>(nil)
    /// How long held input stays worth sending, and how much is held at most.
    static let holdLimit = Duration.seconds(30)
    static let holdBytes = 4096
    /// Bytes requested per history page.
    static let historyPageBytes: UInt32 = 256 * 1024

    init(pane: PaneId, client: any DaemonClientAPI, router: PaneRouter) {
        self.pane = pane
        self.client = client
        self.router = router
        tap = router.register(pane.rawValue)
    }

    public func start(events: @escaping @Sendable (PaneEvent) -> Void) {
        start(events: events, seed: nil)
    }

    public func start(events: @escaping @Sendable (PaneEvent) -> Void, seed: (@Sendable () -> [PaneEvent])?) {
        let sink: @Sendable (PaneEvent) -> Void = { [weak self] event in
            events(event)
            switch event {
            case .snapshot, .output: self?.releaseHeldInput()
            default: break
            }
        }
        if router.start(pane.rawValue, tap: tap, sink: sink, seed: seed) {
            client.subscribe(paneId: pane.rawValue)
        }
    }

    public func claimSize() {
        if let size = router.claim(pane.rawValue, tap: tap) { client.resize(paneId: pane.rawValue, size: size) }
    }

    public func startPredictionFeed(_ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void) {
        router.startPrediction(pane.rawValue, tap: tap, onUpdate)
    }

    private static func isFocusReport(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let hasFocusSuffix = bytes.last == 0x49 || bytes.last == 0x4f
        return hasFocusSuffix && ((bytes.count == 3 && bytes[0] == 0x1b && bytes[1] == 0x5b)
            || (bytes.count == 2 && bytes[0] == 0x9b))
    }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, !hold(.bytes(Data(bytes))), router.admitsInput(pane.rawValue) else { return }
        if !Self.isFocusReport(bytes) { claimSize() }
        router.noteInput(pane.rawValue, tap: tap)
        client.sendInput(paneId: pane.rawValue, data: Data(bytes))
    }

    public func writeInput(_ bytes: UnsafeRawBufferPointer, inputSeq: UInt64) {
        guard !bytes.isEmpty, !hold(.bytes(Data(bytes))), router.admitsInput(pane.rawValue) else { return }
        if !Self.isFocusReport(bytes) { claimSize() }
        router.noteInput(pane.rawValue, tap: tap, predicted: inputSeq)
        client.sendInput(paneId: pane.rawValue, data: Data(bytes))
    }

    public func paste(_ text: String) {
        guard !hold(.paste(text)), router.admitsInput(pane.rawValue) else { return }
        claimSize()
        router.noteInput(pane.rawValue, tap: tap)
        client.sendPaste(paneId: pane.rawValue, text: text)
    }

    public func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        let size = PaneSize(
            cols: cols, rows: rows,
            widthPx: UInt16(clamping: UInt32(cols) * cellWidth),
            heightPx: UInt16(clamping: UInt32(rows) * cellHeight))
        if let sizeToSend = router.resize(pane.rawValue, tap: tap, to: size) {
            client.resize(paneId: pane.rawValue, size: sizeToSend)
        }
    }

    public func requestHistory() -> Bool {
        client.fetchHistory(paneId: pane.rawValue, maxBytes: Self.historyPageBytes)
    }

    // MARK: Input before the host's screen

    /// What happened to input typed over a saved screen.
    public enum HeldInputState: Sendable, Equatable {
        /// Waiting for the host's screen (`count` inputs so far).
        case holding(Int)
        /// The host's screen was the one typed at: sent.
        case sent
        /// The host's screen had changed (or it took too long, or too much was typed): not
        /// sent, so no keystroke lands in a state the user never saw.
        case dropped
    }

    private enum Held: Sendable {
        case bytes(Data)
        case paste(String)
    }

    private struct HeldInput {
        let screen: String
        let current: @Sendable () -> String
        let onChange: @Sendable (HeldInputState) -> Void
        let since = ContinuousClock.now
        var inputs: [Held] = []
        var bytes = 0
        var overflowed = false
    }

    /// Whether the daemon has sent this pane's state on this connection.
    public var isLive: Bool { router.isLive(pane.rawValue) }

    /// The pane shows a saved screen: input waits for the host's. When the host's screen
    /// arrives and reads the same as the saved one (`screen()`, read again then), the input is
    /// sent as if typed now; otherwise it is dropped and `onChange` says so.
    public func holdInputUntilLive(
        screen: @escaping @Sendable () -> String, onChange: @escaping @Sendable (HeldInputState) -> Void
    ) {
        guard !isLive else { return }
        held.withLock { $0 = HeldInput(screen: screen(), current: screen, onChange: onChange) }
    }

    /// Keeps `input` while holding; false when it should be sent now.
    private func hold(_ input: Held) -> Bool {
        let update = held.withLock { held -> (@Sendable (HeldInputState) -> Void, Int)? in
            guard var current = held else { return nil }
            let size = switch input {
            case .bytes(let data): data.count
            case .paste(let text): text.utf8.count
            }
            if current.bytes + size > Self.holdBytes {
                current.overflowed = true
            } else {
                current.inputs.append(input)
                current.bytes += size
            }
            held = current
            return (current.onChange, current.inputs.count)
        }
        guard let (onChange, count) = update else { return false }
        onChange(.holding(count))
        return true
    }

    /// The host's screen is on the terminal now: send or drop what was held.
    private func releaseHeldInput() {
        guard isLive else { return }
        held.withLock { held in
            guard let current = held else { return }
            held = nil
            guard !current.inputs.isEmpty || current.overflowed else { return }
            let fresh = ContinuousClock.now - current.since < Self.holdLimit
            guard fresh, !current.overflowed, current.current() == current.screen,
                  router.admitsInput(pane.rawValue)
            else {
                current.onChange(.dropped)
                return
            }
            claimSize()
            for input in current.inputs {
                router.noteInput(pane.rawValue, tap: tap)
                switch input {
                case .bytes(let data): client.sendInput(paneId: pane.rawValue, data: data)
                case .paste(let text): client.sendPaste(paneId: pane.rawValue, text: text)
                }
            }
            current.onChange(.sent)
        }
    }

    public func terminate() {
        let (last, handover) = router.remove(pane.rawValue, tap: tap)
        if last {
            client.unsubscribe(paneId: pane.rawValue)
        } else if let handover {
            client.resize(paneId: pane.rawValue, size: handover)
        }
    }
}

nonisolated extension PaneEvent {
    /// A remote resize to `size`, with the cell size every VT of the pane uses.
    static func resized(_ size: PaneSize) -> PaneEvent {
        .resized(
            cols: size.cols, rows: size.rows,
            cellWidth: UInt32(size.widthPx / max(size.cols, 1)), cellHeight: UInt32(size.heightPx / max(size.rows, 1)))
    }
}
