import Foundation
import Synchronization
import TerminalCore

/// One pane's backend shared by every window that shows the pane (a local PTY, a plain-SSH
/// channel, the iOS echo stand-in; daemon panes share their connection's `PaneRouter` instead).
/// Each window's `Pane` gets a tap (`makeTap()`): its own terminal fed by the same stream, in
/// the same order. The backend starts with the first tap; a later tap starts from another
/// tap's terminal (`SharedPaneTap.start(events:seed:)`). One size goes to the process: the
/// window that typed or took focus last drives it. The backend ends when its pane leaves the
/// layout (`terminate` on the last tap).
///
/// When the last window showing the pane closes while the pane stays in the layout (`detach`),
/// the stream keeps going into a parked terminal, so a window opened later shows everything
/// (the process keeps running, as a shell in a closed window's tab does on the host).
nonisolated public final class SharedPaneBackend: Sendable {
    public let backend: any PaneBackend

    private struct Tap {
        var sink: (@Sendable (PaneEvent) -> Void)?
        var seed: (@Sendable () -> [PaneEvent])?
        var prediction: (@Sendable (PredictionUpdate) -> Void)?
        var size: (cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)?
    }

    private struct State {
        var taps: [UInt64: Tap] = [:]
        var nextTap: UInt64 = 1
        var started = false
        var driver: UInt64?
        /// The last connection state, replayed to taps that start later.
        var connection: PaneConnection?
        var exited = false
        var hint: PredictionUpdate?
        var terminated = false
        /// Keeps the stream while no window shows the pane (`detach` of the last tap).
        var parked: Terminal?

        var started_: [(UInt64, @Sendable (PaneEvent) -> Void)] {
            taps.sorted { $0.key < $1.key }.compactMap { id, tap in tap.sink.map { (id, $0) } }
        }
    }

    private let state = Mutex(State())
    /// Held while events go to the taps and while a tap is seeded (see `PaneRouter.delivery`).
    private let delivery = Mutex(())

    public init(_ backend: any PaneBackend) {
        self.backend = backend
    }

    /// A new window's view of the pane.
    public func makeTap() -> any SharedPaneTap {
        let id = state.withLock { state in
            defer { state.nextTap += 1 }
            state.taps[state.nextTap] = Tap()
            return state.nextTap
        }
        if backend is any PredictionFeed { return PredictingTap(shared: self, id: id) }
        return BackendTap(shared: self, id: id)
    }

    /// Taps currently attached (tests, diagnostics).
    public var tapCount: Int { state.withLock { $0.taps.count } }

    /// Whether the backend was ended (its pane left the layout).
    public var isTerminated: Bool { state.withLock { $0.terminated } }

    /// Whether the stream is parked (no window shows the pane).
    public var isParked: Bool { state.withLock { $0.parked != nil } }

    // MARK: Taps

    fileprivate func start(_ id: UInt64, sink: @escaping @Sendable (PaneEvent) -> Void, seed: (@Sendable () -> [PaneEvent])?) {
        let startBackend: Bool = delivery.withLock { _ in
            let (first, source, connection, exited) = state.withLock { state in
                let running = state.started_
                let taps = state.taps
                let driver = state.driver
                var source: (@Sendable () -> [PaneEvent])?
                if let parked = state.parked {
                    source = { parked.seedEvents() }
                } else if let driver, running.contains(where: { $0.0 == driver }), let seed = taps[driver]?.seed {
                    source = seed
                } else {
                    source = running.lazy.compactMap { taps[$0.0]?.seed }.first
                }
                state.taps[id]?.sink = sink
                state.taps[id]?.seed = seed
                let first = !state.started
                state.started = true
                return (first, source, state.connection, state.exited)
            }
            if !first {
                if let connection { sink(.connection(connection)) }
                for event in source?() ?? [] { sink(event) }
                if exited { sink(.exited) }
                // Once a window took the stream over, the parked copy is no longer needed.
                state.withLock { $0.parked = nil }
            }
            return first
        }
        guard startBackend else { return }
        backend.start { [weak self] event in self?.deliver(event) }
        if let feed = backend as? any PredictionFeed {
            feed.startPredictionFeed { [weak self] update in self?.predicted(update) }
        }
    }

    private func deliver(_ event: PaneEvent) {
        delivery.withLock { _ in
            let (sinks, parked) = state.withLock { state -> ([@Sendable (PaneEvent) -> Void], Terminal?) in
                switch event {
                case .connection(let connection): state.connection = connection
                case .exited: state.exited = true
                default: break
                }
                return (state.started_.map(\.1), state.parked)
            }
            for sink in sinks { sink(event) }
            if let parked { Self.apply(event, to: parked) }
        }
    }

    /// Predictions belong to the window that types: hints go to every tap, acks to the driver.
    private func predicted(_ update: PredictionUpdate) {
        let targets = state.withLock { state -> [@Sendable (PredictionUpdate) -> Void] in
            if case .acknowledged = update {
                return state.driver.flatMap { state.taps[$0]?.prediction }.map { [$0] } ?? []
            }
            if case .hint = update { state.hint = update }
            return state.taps.values.compactMap(\.prediction)
        }
        for target in targets { target(update) }
    }

    fileprivate func startPrediction(_ id: UInt64, _ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void) {
        let hint = state.withLock { state in
            state.taps[id]?.prediction = onUpdate
            return state.hint
        }
        if let hint { onUpdate(hint) }
    }

    /// Input from a tap: it drives the size from now on.
    fileprivate func claim(_ id: UInt64) {
        let size = state.withLock { state -> (cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)? in
            guard state.driver != id else { return nil }
            let first = state.driver == nil
            state.driver = id
            return first ? nil : state.taps[id]?.size
        }
        if let size { backend.resize(cols: size.cols, rows: size.rows, cellWidth: size.cellWidth, cellHeight: size.cellHeight) }
    }

    fileprivate func resize(_ id: UInt64, cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        let send = state.withLock { state in
            state.taps[id]?.size = (cols, rows, cellWidth, cellHeight)
            if state.driver == nil { state.driver = id }
            return state.driver == id
        }
        if send { backend.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight) }
    }

    /// A tap leaves: its pane left the layout (`terminate`: the last one ends the backend) or
    /// its window closed (`park`: the last one keeps the stream in a parked terminal).
    fileprivate func remove(_ id: UInt64, park: Bool) {
        // Parking copies the leaving tap's terminal, so nothing between the copy and the parked
        // terminal taking over is lost: under the delivery lock.
        let (end, handover) = delivery.withLock { _ in
            state.withLock { state -> (Bool, (cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)?) in
                let seed = state.taps[id]?.seed
                state.taps[id] = nil
                var handover: (cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32)?
                if state.driver == id {
                    let next = state.taps.filter { $0.value.size != nil }.min { $0.key < $1.key }
                    state.driver = next?.key
                    handover = next?.value.size
                }
                guard state.taps.isEmpty, !state.terminated else { return (false, handover) }
                if park, state.started, !state.exited, let seed {
                    let parked = Terminal(cols: 80, rows: 24) { [backend] in backend.write($0) }
                    parked.answersQueries = !backend.hostAnswersQueries
                    if let limit = backend.kittyImageStorageLimit { parked.kittyImageStorageLimit = limit }
                    for event in seed() { Self.apply(event, to: parked) }
                    state.parked = parked
                    return (false, nil)
                }
                state.terminated = true
                state.parked = nil
                return (true, nil)
            }
        }
        if end {
            backend.terminate()
        } else if let handover {
            backend.resize(cols: handover.cols, rows: handover.rows, cellWidth: handover.cellWidth, cellHeight: handover.cellHeight)
        }
    }

    /// Ends the backend whether or not windows show it (its pane left the layout while parked).
    public func terminate() {
        let end = state.withLock { state in
            guard !state.terminated else { return false }
            state.terminated = true
            state.parked = nil
            return true
        }
        if end { backend.terminate() }
    }

    private static func apply(_ event: PaneEvent, to terminal: Terminal) {
        switch event {
        case .output(let data): data.withUnsafeBytes { terminal.write($0) }
        case .snapshot(let data): try? terminal.restore(snapshot: data)
        case .history(let data, _): _ = try? terminal.appendHistory(data)
        case .resized(let cols, let rows, let cellWidth, let cellHeight):
            terminal.resize(cols: cols, rows: rows, cellWidth: max(cellWidth, 1), cellHeight: max(cellHeight, 1))
        case .connection, .exited, .sizingChanged: break
        }
    }

    // MARK: Tap types

    fileprivate class BackendTap: SharedPaneTap, @unchecked Sendable {
        let shared: SharedPaneBackend
        let id: UInt64

        init(shared: SharedPaneBackend, id: UInt64) {
            self.shared = shared
            self.id = id
        }

        func start(events: @escaping @Sendable (PaneEvent) -> Void) {
            shared.start(id, sink: events, seed: nil)
        }

        func start(events: @escaping @Sendable (PaneEvent) -> Void, seed: (@Sendable () -> [PaneEvent])?) {
            shared.start(id, sink: events, seed: seed)
        }

        func claimSize() { shared.claim(id) }

        func write(_ bytes: UnsafeRawBufferPointer) {
            shared.claim(id)
            shared.backend.write(bytes)
        }

        func writeGenerated(_ bytes: UnsafeRawBufferPointer) {
            shared.backend.writeGenerated(bytes)
        }

        func paste(_ text: String) {
            shared.claim(id)
            shared.backend.paste(text)
        }

        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
            shared.resize(id, cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        }

        var sizeFollowsStream: Bool { shared.backend.sizeFollowsStream }
        var hostAnswersQueries: Bool { shared.backend.hostAnswersQueries }
        var kittyImageStorageLimit: UInt64? { shared.backend.kittyImageStorageLimit }
        func requestHistory() -> Bool { shared.backend.requestHistory() }
        func terminate() { shared.remove(id, park: false) }
        func detach() { shared.remove(id, park: true) }
        func foreground() -> PaneForeground? { shared.backend.foreground() }
    }

    fileprivate final class PredictingTap: BackendTap, PredictionFeed, @unchecked Sendable {
        func startPredictionFeed(_ onUpdate: @escaping @Sendable (PredictionUpdate) -> Void) {
            shared.startPrediction(id, onUpdate)
        }

        func writeInput(_ bytes: UnsafeRawBufferPointer, inputSeq: UInt64) {
            shared.claim(id)
            (shared.backend as? any PredictionFeed)?.writeInput(bytes, inputSeq: inputSeq)
        }
    }
}

extension SharedPaneBackend {
    /// The backend a tap wraps (debug tooling: a local PTY's pid).
    public static func underlying(_ backend: any PaneBackend) -> (any PaneBackend)? {
        (backend as? BackendTap)?.shared.backend
    }
}
