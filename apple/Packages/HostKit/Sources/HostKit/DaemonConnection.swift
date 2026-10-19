import Foundation
import Observation
import os
import PaneLayout
import UnnamedCore

/// What a window needs from a host, whatever kind it is: a layout store, pane backends, a
/// status, and the lifecycle hooks (04-mobile-ux R1–R12). The connection is a stable logical
/// handle; the transport underneath is swapped on reconnect, never the object views hold (R7).
@MainActor
public protocol HostConnection: AnyObject, Observable {
    var status: ConnectionStatus { get }
    var layoutStore: any LayoutStore { get }
    /// False until there is a layout to show (a daemon host before its first `LayoutChanged`).
    var isReady: Bool { get }
    func makeBackend(for pane: PaneId) throws -> any PaneBackend
    /// User asked to retry (R9); also resets backoff (R10).
    func retry()
    /// App came to the foreground: probe and resume now (R1, R10).
    func foreground()
    /// App went to the background (iOS): suspend, keeping resume state (R3, R5).
    func background()
    /// The network path changed: redial or probe now (R10).
    func networkChanged()
    func close()
}

/// A paired daemon: one `DaemonClient` (iroh), its layout and its panes.
@MainActor
@Observable
public final class DaemonConnection: HostConnection {
    public let hostId: String
    public private(set) var status: ConnectionStatus = .idle
    public let layout: DaemonLayoutStore
    /// Pane metadata (title, cwd, agent) by pane.
    public private(set) var meta: [PaneId: PaneMeta] = [:]
    /// Panes whose agent waits for a decision.
    public var blockedAgents: [PaneId: AgentStatus] {
        meta.compactMapValues { meta in
            guard let agent = meta.agent, case .blocked = agent.state else { return nil }
            return agent
        }
    }
    /// Latest keystroke-to-echo round trip.
    public private(set) var echoRoundTrip: Duration?
    /// Timings of the current connection, for diagnostics and the report.
    public private(set) var timings = Timings()
    /// How many times this connection dialled or redialled (connect, retry, foreground and
    /// network-change resumes). Switching between hosts in a window must not change it.
    @ObservationIgnored public private(set) var dials = 0
    /// Called when a layout or connection change should be persisted (the attached session).
    @ObservationIgnored public var onAttached: ((UInt64) -> Void)?

    public struct Timings: Sendable, Equatable {
        public var dialStarted: ContinuousClock.Instant?
        public var connected: Duration?
        public var firstLayout: Duration?
        public var firstOutput: Duration?
    }

    public var layoutStore: any LayoutStore { layout }
    public var isReady: Bool { layout.hasLayout }

    @ObservationIgnored private let ticket: String
    @ObservationIgnored private let dialer: DaemonDialer
    @ObservationIgnored private var client: (any DaemonClientAPI)?
    @ObservationIgnored let router: PaneRouter
    @ObservationIgnored private var events: AsyncStream<ClientEvent>.Continuation?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var epoch: UInt64?
    @ObservationIgnored private var attachSession: UInt64?
    @ObservationIgnored private var lastView: (UInt64?, [UInt64])?
    @ObservationIgnored private var attempt: UInt32 = 0
    @ObservationIgnored private var sawOutput = false

    private static let log = Logger(subsystem: Log.subsystem, category: "daemon")

    /// - Parameters:
    ///   - ticket: the pairing ticket; after pairing it still names the daemon (its key and
    ///     addresses) and the device grant is used.
    ///   - session: the daemon session to attach (nil: the most recent).
    public init(hostId: String, ticket: String, session: UInt64? = nil, dialer: @escaping DaemonDialer) {
        self.hostId = hostId
        self.ticket = ticket
        self.dialer = dialer
        attachSession = session
        var sendOp: ((UnnamedCore.LayoutOp) -> UInt64)?
        layout = DaemonLayoutStore { op in sendOp?(op) ?? 0 }
        let echo = AsyncStream<Duration>.makeStream()
        router = PaneRouter { echo.continuation.yield($0) }
        sendOp = { [weak self] op in self?.client?.op(op: op) ?? 0 }
        Task { [weak self] in
            for await rtt in echo.stream {
                guard let self else { return }
                echoRoundTrip = rtt
                if case .connected = status { status = .connected(rtt: rtt) }
                Self.log.debug("echo rtt \(rtt / .milliseconds(1), format: .fixed(precision: 1)) ms host=\(self.hostId, privacy: .public)")
            }
        }
        observeView()
    }

    /// Dials the daemon. Errors are a bad ticket or device key (nothing to retry).
    public func connect() throws {
        guard client == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: ClientEvent.self)
        events = continuation
        let router = router
        let listener = ClosureListener { event in
            router.route(event)
            if case .paneBytes = event { return }
            continuation.yield(event)
        }
        status = .connecting
        dials += 1
        timings = Timings(dialStarted: .now)
        Self.log.info("dialing host=\(self.hostId, privacy: .public)")
        let client = try dialer(ticket, listener)
        self.client = client
        pump = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    public func makeBackend(for pane: PaneId) throws -> any PaneBackend {
        guard let client else { throw HostError.notConnected }
        return DaemonPaneBackend(pane: pane, client: client, router: router)
    }

    public func retry() {
        attempt = 0
        if client == nil {
            try? connect()
        } else {
            status = .connecting
            dials += 1
            client?.reconnect()
        }
    }

    public func foreground() {
        guard let client else { return }
        if case .connected = status { return }
        Self.log.info("foreground: resuming host=\(self.hostId, privacy: .public)")
        dials += 1
        timings.dialStarted = .now
        client.reconnect()
    }

    public func background() {
        guard let client else { return }
        router.suspend()
        client.suspend()
        status = .suspended
    }

    public func networkChanged() {
        guard let client else { return }
        if case .suspended = status { return }
        Self.log.info("network changed: redialing host=\(self.hostId, privacy: .public)")
        dials += 1
        timings.dialStarted = .now
        client.reconnect()
    }

    public func close() {
        pump?.cancel()
        events?.finish()
        client = nil
        status = .idle
    }

    /// Answers a blocked agent.
    public func decide(requestId: UInt64, optionId: UInt32) {
        client?.decide(requestId: requestId, optionId: optionId)
    }

    /// Visible text of a pane from the core's VT mirror (tests and diagnostics; needs
    /// `mirrorVt`).
    public func paneText(_ pane: PaneId) -> String? {
        client?.paneText(paneId: pane.rawValue)
    }

    // MARK: Events (main actor, in order)

    func handle(_ event: ClientEvent) {
        switch event {
        case .connected(let epoch, let resumed):
            if let previous = self.epoch, previous != epoch { layout.resetRevision() }
            self.epoch = epoch
            attempt = 0
            status = .connected(rtt: echoRoundTrip)
            if let start = timings.dialStarted { timings.connected = .now - start }
            Self.log.info("connected host=\(self.hostId, privacy: .public) resumed=\(resumed) after \(self.timings.connected.map { $0 / .milliseconds(1) } ?? -1, format: .fixed(precision: 1)) ms")
            if !resumed { client?.attach(sessionId: attachSession) }
            lastView = nil
            pushView()
        case .disconnected(let reason):
            if case .suspended = status { return }
            attempt += 1
            status = .reconnecting(attempt: attempt, reason: reason)
            Self.log.info("disconnected host=\(self.hostId, privacy: .public): \(reason, privacy: .public)")
        case .refused(let reason):
            status = .needsAttention(reason: "Refused: \(reason)")
            Self.log.error("refused host=\(self.hostId, privacy: .public): \(reason, privacy: .public)")
        case .attached(let session):
            attachSession = session
            onAttached?(session)
        case .layout(let layout):
            self.layout.receive(layout)
            if timings.firstLayout == nil, let start = timings.dialStarted { timings.firstLayout = .now - start }
            pushView()
        case .paneMeta(let meta):
            self.meta[PaneId(meta.paneId)] = meta
        case .paneClosed(let pane):
            meta[PaneId(pane)] = nil
        case .opResult(_, let outcome):
            if case .failed = outcome { layout.revertToConfirmed() }
        case .paneSnapshot, .paneResized:
            noteOutput()
        default:
            break
        }
    }

    private func noteOutput() {
        guard !sawOutput, let start = timings.dialStarted else { return }
        sawOutput = true
        timings.firstOutput = .now - start
        Self.log.info("first paint host=\(self.hostId, privacy: .public) after \(self.timings.firstOutput.map { $0 / .milliseconds(1) } ?? -1, format: .fixed(precision: 1)) ms")
    }

    /// Keeps the daemon's idea of what is on screen current (stream priorities, budgets).
    private func observeView() {
        withObservationTracking {
            _ = layout.session
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.pushView()
                self?.observeView()
            }
        }
    }

    private func pushView() {
        guard let client else { return }
        let view = layout.view
        if let lastView, lastView.0 == view.focused, lastView.1 == view.visible { return }
        lastView = (view.focused, view.visible)
        client.setView(focused: view.focused, visible: view.visible)
    }
}

public enum HostError: Error, Equatable, LocalizedError {
    case notConnected
    case badTicket(String)
    case missingSecret(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected"
        case .badTicket(let reason): "That is not a valid pairing ticket: \(reason)"
        case .missingSecret(let what): "Missing \(what)"
        }
    }
}

nonisolated enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "dev.unnamed.app"
}
