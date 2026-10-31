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
    /// Showing the layout this device saved last, not yet the host's (instant start): its
    /// tabs and panes show, ops wait.
    var showsCachedLayout: Bool { get }
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

public extension HostConnection {
    var showsCachedLayout: Bool { false }
}

/// A paired daemon: one `DaemonClient` (iroh), its layout and its panes.
@MainActor
@Observable
public final class DaemonConnection: HostConnection {
    public let hostId: String
    public private(set) var status: ConnectionStatus = .idle
    public let layout: DaemonLayoutStore
    /// Pane metadata (title, cwd, agent) by pane, observed per pane.
    public let meta = PaneTable<PaneMeta>()
    /// What any program in a pane last reported about itself (OSC 7501, `status_set`), by pane.
    /// A blocked report is a status only: approvals stay in `meta[pane].agent`.
    public let programs = PaneTable<ProgramReport>()
    /// Panes whose agent waits for a decision.
    public var blockedAgents: [PaneId: AgentStatus] {
        meta.all.compactMapValues { meta in
            guard let agent = meta.agent, case .blocked = agent.state else { return nil }
            return agent
        }
    }
    /// Keystroke-to-echo round trip: the median of the last five.
    public private(set) var echoRoundTrip: Duration?
    /// Timings of the current connection, for diagnostics and the report.
    public private(set) var timings = Timings()
    /// How many times this connection dialled or redialled (connect, retry, foreground and
    /// network-change resumes). Switching between hosts in a window must not change it.
    @ObservationIgnored public private(set) var dials = 0
    /// Called when a layout or connection change should be persisted (the attached session).
    @ObservationIgnored public var onAttached: ((UInt64) -> Void)?
    /// Something the user should hear about once (the remembered session was gone). The UI
    /// shows it and calls `dismissNotice()`.
    public private(set) var notice: HostNotice?
    /// Every non-pane-stream event, on the main actor after the connection handled it (search,
    /// links and command-output answers for `DaemonWorkspace`, `.connected` to re-watch).
    @ObservationIgnored public var onEvent: ((ClientEvent) -> Void)?
    /// A program in a pane this device typed into last wrote to the clipboard (OSC 52): the
    /// pane and the text.
    @ObservationIgnored public var onClipboard: ((PaneId, String) -> Void)?
    /// Who is here, roles, control leases, invites and the audit log (docs/DAEMON.md §6).
    public let multiplayer = MultiplayerSession()
    /// Native password prompts from this host's panes (docs/DAEMON.md §9).
    public let askpass = AskpassSession()
    /// Approve with an edited command, auto-approve rules (docs/DAEMON.md §6.9).
    public let approvals = ApprovalSession()
    /// URLs this host's panes open and browser tools its agents call.
    public let browser = BrowserSession()
    /// The daemon's workspace pushes (attention feed, ports, files), fanned out to observers.
    @ObservationIgnored public let workspaceEvents = WorkspaceEventHub()
    /// What the daemon said about itself on the latest connection (build, protocol level,
    /// machine); nil for daemons that predate it (`daemonInfoReported` tells them apart from
    /// "not yet").
    public private(set) var daemonInfo: DaemonInfo?
    /// A `daemonInfo` event arrived (with or without info).
    public private(set) var daemonInfoReported = false
    /// Why the core cannot work with this daemon (it draws terminals in another format), until
    /// a connection works again. The daemon may still accept an update over this connection.
    public private(set) var incompatibility: String?
    /// Called on the main actor with every `daemonInfo` event (host names, helper versions).
    @ObservationIgnored public var onDaemonInfo: ((DaemonInfo?) -> Void)?

    public struct Timings: Sendable, Equatable {
        public var dialStarted: ContinuousClock.Instant?
        public var connected: Duration?
        public var firstLayout: Duration?
        public var firstOutput: Duration?
    }

    public var layoutStore: any LayoutStore { layout }
    public var isReady: Bool { layout.hasLayout }
    public var showsCachedLayout: Bool { layout.isCached }
    /// Saved screens of panes the daemon has not sent yet (instant start).
    @ObservationIgnored private var cachedPanes: [PaneId: CachedPane] = [:]

    @ObservationIgnored private let ticket: String
    @ObservationIgnored private let dialer: DaemonDialer
    @ObservationIgnored private(set) var client: (any DaemonClientAPI)?
    @ObservationIgnored var pushClient: (any PushClientAPI)?
    @ObservationIgnored let router: PaneRouter
    @ObservationIgnored private var events: AsyncStream<ClientEvent>.Continuation?
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Metadata and program reports held back, newest per pane (`paneStatus`).
    @ObservationIgnored private var pendingMeta: [PaneId: PaneMeta] = [:]
    @ObservationIgnored private var pendingPrograms: [PaneId: ProgramReport?] = [:]
    @ObservationIgnored private lazy var paneStatus = UpdateThrottle(interval: Self.paneStatusInterval) { [weak self] in
        self?.applyPaneStatus()
    }
    /// The most often pane metadata reaches views while it keeps changing.
    static let paneStatusInterval = Duration.milliseconds(50)
    /// The daemon run (changes when the daemon restarts).
    public private(set) var epoch: UInt64?
    @ObservationIgnored private var attachSession: UInt64?
    @ObservationIgnored private var lastView: (UInt64?, [UInt64])?
    @ObservationIgnored private var attempt: UInt32 = 0
    @ObservationIgnored private var sawOutput = false
    /// Between `Attach` and the session's first layout (status `.connecting(.openingSession)`).
    @ObservationIgnored private var attaching = false

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
            var recent: [Duration] = []
            for await rtt in echo.stream {
                guard let self else { return }
                // The median of the last five, so one slow keystroke does not flag the link.
                recent = Array((recent + [rtt]).suffix(5))
                echoRoundTrip = recent.sorted()[recent.count / 2]
                if case .connected = status { status = .connected(rtt: echoRoundTrip) }
                Self.log.debug("echo rtt \(rtt / .milliseconds(1), format: .fixed(precision: 1)) ms host=\(self.hostId, privacy: .public)")
            }
        }
        observeView()
        let router = router
        let session = multiplayer
        multiplayer.onInputGate = { [weak session] gate in
            router.setGate(gate) { [weak session] pane in
                Task { @MainActor [weak session] in session?.noteBlockedInput(pane) }
            }
        }
    }

    /// Dials the daemon. Errors are a bad ticket or device key (nothing to retry).
    public func connect() throws {
        guard client == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: ClientEvent.self)
        events = continuation
        let router = router
        let listener = ClosureListener { event in
            guard router.route(event) else {
                continuation.yield(event)
                return
            }
            // Pane-stream events are applied here; the main actor only notes the first paint,
            // so snapshots and history pages are not queued for it.
            switch event {
            case .paneSnapshot(let pane, let seq, _): continuation.yield(.paneSnapshot(paneId: pane, seq: seq, data: Data()))
            case .paneResized: continuation.yield(event)
            default: break
            }
        }
        status = .connecting(.dialing)
        dials += 1
        timings = Timings(dialStarted: .now)
        Self.log.info("dialing host=\(self.hostId, privacy: .public)")
        let client = try dialer(ticket, listener)
        self.client = client
        if let mp = client as? any MultiplayerClientAPI { multiplayer.attach(mp) }
        if let ap = client as? any AskpassClientAPI { askpass.attach(ap) }
        if let ac = client as? any ApprovalClientAPI { approvals.attach(ac) }
        if let bc = client as? any BrowserClientAPI { browser.attach(bc) }
        if let source = client as? any WorkspaceEventSource { workspaceEvents.attach(source) }
        pushClient = client as? any PushClientAPI
        pump = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    /// Types `text` into a pane as a paste, then Return (a code a program waits for).
    public func type(_ text: String, into pane: UInt64) {
        paste(text, into: pane)
        client?.sendInput(paneId: pane, data: Data("\r".utf8))
    }

    /// Pastes `text` into a pane, for the user to send.
    public func paste(_ text: String, into pane: UInt64) {
        client?.sendPaste(paneId: pane, text: text)
    }

    /// Reopens a closed tab on this host (its agent resuming its session) and returns the
    /// new tab, selected.
    public func reopenTab(closedPane: UInt64?, directory: String?, name: String) async throws -> TabRef {
        guard let session = layout.sessionId, let client = client as? any TabHistoryClient else { throw HostError.notConnected }
        // No pane to reopen (a tab closed elsewhere than a daemon): a shell in its directory.
        let made = try await client.reopenTab(sessionId: session, closedPane: closedPane ?? 0, cwd: directory, name: name)
        return TabRef(hostId: hostId, tab: TabId(made.tabId))
    }

    /// The pane's foreground program and prompt now (nil when the host can't say).
    public func paneAssist(_ pane: PaneId) async -> PaneAssist? {
        guard let client = client as? any TabHistoryClient else { return nil }
        return try? await client.paneAssist(paneId: pane.rawValue)
    }

    /// Shows what this device saved of the host until the daemon answers: the layout, names,
    /// projects and each pane's last screen (docs/APP-ARCHITECTURE.md §26).
    public func seed(_ cached: CachedWorkspace) {
        guard !layout.hasLayout else { return }
        layout.seed(cached.session, name: cached.sessionName, projects: cached.projects)
        for (id, pane) in cached.panes {
            meta.set(PaneMeta(
                paneId: id, title: pane.title, cwd: pane.cwd, exit: nil, agent: nil,
                size: PaneSize(cols: pane.cols, rows: pane.rows, widthPx: 0, heightPx: 0),
                sizePolicy: .lastInput, sizedBy: nil), for: PaneId(id))
        }
        cachedPanes = Dictionary(uniqueKeysWithValues: cached.panes.map { (PaneId($0.key), $0.value) })
    }

    /// What to save of this host now (no screens yet: `CachedWorkspace.capturingScreens` adds
    /// them off the main actor). Nil until the daemon's own layout is here.
    public func workspaceToSave(daemonId: String?) -> CachedWorkspace? {
        guard layout.hasLayout else { return nil }
        let session = layout.session
        var panes: [UInt64: CachedPane] = [:]
        for pane in session.panes {
            let meta = meta[pane]
            panes[pane.rawValue] = CachedPane(
                title: meta?.title ?? "", cwd: meta?.cwd, cols: meta?.size.cols ?? 0, rows: meta?.size.rows ?? 0)
        }
        return CachedWorkspace(
            hostId: hostId, daemonId: daemonId, sessionId: layout.sessionId, sessionName: layout.sessionName,
            session: session, projects: layout.projects, panes: panes)
    }

    /// A pane's saved screen while the daemon has not sent its own.
    public func cachedScreen(for pane: PaneId) -> CachedPane? {
        guard let cached = cachedPanes[pane], !router.isLive(pane.rawValue) else { return nil }
        return cached
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
            status = .connecting(.dialing)
            dials += 1
            client?.reconnect()
        }
    }

    /// Back in the foreground: a connection that is not up (suspended, or lost meanwhile) is
    /// redialled now; one up or already dialling is left alone.
    public func foreground() {
        guard let client else { return }
        switch status {
        case .connected, .connecting: return
        default: break
        }
        Self.log.info("foreground: resuming host=\(self.hostId, privacy: .public)")
        status = .connecting(.dialing)
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

    /// A live connection moves to the new path by itself (its streams, forwarded editors
    /// among them, survive); one that is down is redialled at once.
    public func networkChanged() {
        guard let client else { return }
        if case .suspended = status { return }
        if case .connected = status, let roaming = client as? any NetworkChangeClient {
            Self.log.info("network changed: keeping the connection host=\(self.hostId, privacy: .public)")
            roaming.networkChanged()
            return
        }
        Self.log.info("network changed: redialing host=\(self.hostId, privacy: .public)")
        dials += 1
        timings.dialStarted = .now
        client.reconnect()
    }

    /// The relay settings changed: redial on an endpoint built from them. Panes resume as
    /// after any reconnect; a suspended connection uses them when it resumes.
    public func setRelays(_ relay: RelayMode, options: ConnectOptions) {
        guard let client = client as? any RelaySettingsClient else { return }
        Self.log.info("relay settings changed: redialing host=\(self.hostId, privacy: .public)")
        if status != .suspended {
            status = .connecting(.dialing)
            dials += 1
            timings.dialStarted = .now
        }
        client.setRelays(relay: relay, options: options)
    }

    public func close() {
        multiplayer.detach()
        askpass.detach()
        approvals.detach()
        browser.detach()
        pump?.cancel()
        events?.finish()
        // Pane backends still on screen hold the client: stop it rather than only letting go,
        // or it keeps streaming and redialling for panes of a host the user disconnected.
        client?.suspend()
        router.broadcast(.stale(reason: "Disconnected"))
        paneStatus.cancel()
        client = nil
        status = .idle
    }

    public func dismissNotice() {
        notice = nil
    }

    /// The words for a failed attach: the daemon's code decides, its message is a fallback.
    static func attachFailure(_ code: OpErrorCode, _ message: String) -> String {
        switch code {
        case .notFound: "The session you were invited to has ended."
        case .forbidden: "You don't have access to a session on this host."
        case .spawnFailed: "The host couldn't start a shell for a new session."
        case .nameTaken, .invalid: message
        }
    }

    /// The status line while the core and the daemon cannot work together.
    static let incompatibleWords = "This host's helper needs an update"

    /// Sends a daemon build (an executable or its gzip) to the daemon, which checks it, swaps
    /// it in and restarts; the connection then drops and comes back by itself on the new
    /// build. Owner devices only.
    public func updateHelper(path: String, build: String, progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) async throws -> DaemonInfo {
        guard let upgrader = client as? any DaemonUpgradeAPI else { throw HostError.notConnected }
        Self.log.info("updating helper host=\(self.hostId, privacy: .public) to \(build, privacy: .public)")
        return try await upgrader.upgradeDaemon(path: path, build: build, progress: progress.map { TransferProgressHandler($0) })
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

    private func applyPaneStatus() {
        guard !pendingMeta.isEmpty || !pendingPrograms.isEmpty else { return }
        let metas = pendingMeta, reports = pendingPrograms
        pendingMeta = [:]
        pendingPrograms = [:]
        for (pane, value) in metas { meta.set(value, for: pane) }
        for (pane, report) in reports { programs.set(report, for: pane) }
    }

    func handle(_ event: ClientEvent) {
        switch event {
        case .paneMeta(let meta):
            pendingMeta[PaneId(meta.paneId)] = meta
            paneStatus.note()
            return
        case .programStatus(let pane, let status):
            pendingPrograms[PaneId(pane)] = .some(status)
            paneStatus.note()
            return
        default:
            // Everything else keeps its order after the pane updates before it.
            applyPaneStatus()
        }
        switch event {
        case .daemonInfo(let info):
            daemonInfo = info
            layout.supportsProjects = info?.projects ?? false
            daemonInfoReported = true
            onDaemonInfo?(info)
        case .incompatible(let reason):
            incompatibility = reason
            attaching = false
            status = .needsAttention(reason: Self.incompatibleWords)
            Self.log.error("incompatible host=\(self.hostId, privacy: .public): \(reason, privacy: .public)")
        case .connected(let epoch, let resumed):
            incompatibility = nil
            if let previous = self.epoch, previous != epoch { layout.resetRevision() }
            self.epoch = epoch
            attempt = 0
            if let start = timings.dialStarted { timings.connected = .now - start }
            Self.log.info("connected host=\(self.hostId, privacy: .public) resumed=\(resumed) after \(self.timings.connected.map { $0 / .milliseconds(1) } ?? -1, format: .fixed(precision: 1)) ms")
            // Live only once there is a session to show: a resumed connection keeps its
            // attachment; a new one attaches and waits for the layout.
            if resumed, layout.hasLayout {
                status = .connected(rtt: echoRoundTrip)
            } else {
                status = .connecting(.openingSession)
                attaching = true
                client?.attach(sessionId: attachSession)
            }
            lastView = nil
            pushView()
        case .disconnected(let reason):
            if case .suspended = status { return }
            attempt += 1
            status = .reconnecting(attempt: attempt, reason: reason)
            Self.log.info("disconnected host=\(self.hostId, privacy: .public): \(reason, privacy: .public)")
        case .refused(let reason):
            status = .needsAttention(reason: incompatibility == nil ? "Refused: \(reason)" : Self.incompatibleWords)
            Self.log.error("refused host=\(self.hostId, privacy: .public): \(reason, privacy: .public)")
        case .attached(let session, let via, let missing):
            attachSession = session
            onAttached?(session)
            if let missing {
                Self.log.info("session \(missing) is gone on host=\(self.hostId, privacy: .public); attached \(session) (\(String(describing: via), privacy: .public))")
                notice = HostNotice(sessionGone: missing, via: via)
            }
        case .attachFailed(let code, let message):
            attaching = false
            Self.log.error("attach failed host=\(self.hostId, privacy: .public): \(message, privacy: .public)")
            status = .needsAttention(reason: Self.attachFailure(code, message))
        case .layout(let layout):
            let wasCached = self.layout.isCached
            self.layout.receive(layout)
            if wasCached { reconcileCache() }
            if timings.firstLayout == nil, let start = timings.dialStarted { timings.firstLayout = .now - start }
            if attaching {
                attaching = false
                status = .connected(rtt: echoRoundTrip)
            }
            pushView()
        case .paneMeta, .programStatus:
            break
        case .paneClosed(let pane):
            meta.set(nil, for: PaneId(pane))
            programs.set(nil, for: PaneId(pane))
        case .sessions(let sessions):
            // The attached session was closed elsewhere (another device, the CLI): drop its tabs
            // at once and attach to what the host has now, never keeping panes that are gone.
            if let current = layout.sessionId, !sessions.contains(where: { $0.sessionId == current }) {
                Self.log.info("session \(current) closed on host=\(self.hostId, privacy: .public); attaching anew")
                layout.sessionGone()
                attachSession = nil
                client?.attach(sessionId: nil)
            }
        case .opResult(let id, let outcome):
            if case .failed = outcome {
                layout.acknowledge(id, failed: true)
            } else {
                layout.acknowledge(id, failed: false)
            }
        case .projects(let report):
            layout.receive(report)
        case .clipboard(let pane, let text):
            onClipboard?(PaneId(pane), text)
        case .paneSnapshot(let pane, _, _):
            cachedPanes[PaneId(pane)] = nil
            noteOutput()
        case .paneResized:
            noteOutput()
        default:
            break
        }
        onEvent?(event)
    }

    /// The daemon's layout replaced the saved one: what it no longer has goes (tabs closed
    /// elsewhere); its own metadata follows for the rest.
    private func reconcileCache() {
        let live = layout.session.panes
        for pane in meta.all.keys where !live.contains(pane) { meta.set(nil, for: pane) }
        cachedPanes = cachedPanes.filter { live.contains($0.key) }
        Self.log.info("saved workspace replaced by the host's host=\(self.hostId, privacy: .public)")
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

    /// What each window shows of this host (`setWindowView`), most recent last. Until a window
    /// reports, the layout's own active tab stands in.
    @ObservationIgnored private var windowViews: [(owner: ObjectIdentifier, focused: UInt64?, visible: [UInt64])] = []
    /// A window has reported: from then on no entry means nothing of this host is on screen
    /// (the app in the background, another host in front), so the daemon notifies.
    @ObservationIgnored private var windowsReported = false

    /// A window shows `visible` of this host with `focused` taking keys (nil focused and empty
    /// visible: the window does not show the host now). The daemon hears the union of every
    /// window's panes and the focus of the window that reported last.
    public func setWindowView(_ window: AnyObject, focused: PaneId?, visible: [PaneId]) {
        let owner = ObjectIdentifier(window)
        windowsReported = true
        windowViews.removeAll { $0.owner == owner }
        if focused != nil || !visible.isEmpty {
            windowViews.append((owner, focused?.rawValue, visible.map(\.rawValue)))
        }
        pushView()
    }

    /// The view this connection last told the daemon (tests, diagnostics).
    public var reportedView: (focused: UInt64?, visible: [UInt64])? { lastView.map { ($0.0, $0.1) } }

    private var combinedView: (focused: UInt64?, visible: [UInt64]) {
        guard windowsReported else { return layout.view }
        var visible: [UInt64] = []
        for view in windowViews { for pane in view.visible where !visible.contains(pane) { visible.append(pane) } }
        let focused = windowViews.last { $0.focused != nil }?.focused
        return (focused, visible)
    }

    private func pushView() {
        guard let client else { return }
        let view = combinedView
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
        case .notConnected: "The host is not connected. It will resume when it is back."
        case .badTicket(let reason): "That is not a valid pairing ticket: \(reason)"
        case .missingSecret(let what): "Missing \(what)"
        }
    }
}

nonisolated enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "dev.unnamed.app"
}

/// A one-time message about a host, shown as a toast.
nonisolated public struct HostNotice: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let text: String

    init(sessionGone missing: UInt64, via: AttachVia) {
        text = switch via {
        case .created: "Your previous session ended. Started a new one."
        case .mostRecent, .requested: "Your previous session ended. Showing the most recent one."
        }
    }
}
