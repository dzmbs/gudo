import Observation
import PaneLayout
import GudoCore

/// A `LayoutStore` whose source of truth is the daemon (docs/DAEMON.md §1): `apply` sends the
/// op to the daemon and `session` is whatever `LayoutChanged` last said. Ops that only move
/// focus, order or names are applied locally at once too and kept until the daemon acknowledges
/// them: every layout that arrives meanwhile gets them replayed on top, so an older echo never
/// shows a tab back where it was. Ops that create or end panes wait for the daemon, which
/// allocates the ids. The session's projects (`ServerCtl::Projects`) work the same way.
@MainActor
@Observable
public final class DaemonLayoutStore: LayoutStore {
    public private(set) var session: Session
    /// The attached daemon session, once known.
    public private(set) var sessionId: UInt64?
    /// Whether a layout has arrived since attaching (views show "Connecting…" until then).
    public private(set) var hasLayout = false
    /// Showing the layout this device saved last (instant start) until the daemon's arrives.
    /// Ops wait for the daemon: there is no session to send them to yet.
    public private(set) var isCached = false
    /// The daemon session's name.
    public private(set) var sessionName = ""
    /// The session's projects as last reported, with unacknowledged changes on top.
    public private(set) var projects = HostProjects()
    /// Whether the daemon keeps projects (`DaemonFeatures::PROJECTS`).
    public var supportsProjects = false
    /// Whether the daemon keeps floating windows (`DaemonFeatures::FLOATS`).
    public var supportsFloats = false

    private enum Pending {
        case layout(PaneLayout.LayoutOp)
        case project(ProjectChange)
    }

    @ObservationIgnored private var revision: UInt64?
    @ObservationIgnored private var projectsRevision: UInt64?
    @ObservationIgnored private var confirmed: Session
    @ObservationIgnored private var confirmedProjects = HostProjects()
    @ObservationIgnored private var confirmedFloats: [FloatWindow] = []
    @ObservationIgnored private var floatsRevision: UInt64?
    /// A layout waiting for its floats (sent right after it), so a new window never shows
    /// for a frame as the split it is in the tree.
    @ObservationIgnored private var heldLayout: SessionLayout?
    @ObservationIgnored private var heldTimeout: Task<Void, Never>?
    /// The held layout's projects: the daemon sends them between the layout and its floats,
    /// and a first layout's report would otherwise be dropped as another session's.
    @ObservationIgnored private var heldProjects: DaemonProjects?
    /// How long a layout waits for its floats before it shows anyway.
    @ObservationIgnored public var floatsWait = Duration.milliseconds(250)
    @ObservationIgnored private var pending: [(id: UInt64, change: Pending)] = []
    @ObservationIgnored private let send: (GudoCore.LayoutOp) -> UInt64

    /// `send` delivers an op to the daemon and returns its id (`DaemonClient.op`).
    public init(send: @escaping (GudoCore.LayoutOp) -> UInt64) {
        self.send = send
        let empty = Session(tabs: [], activeTabId: nil)
        session = empty
        confirmed = empty
    }

    public func apply(_ op: PaneLayout.LayoutOp) {
        guard let sessionId, let daemonOp = LayoutConversion.op(op, sessionId: sessionId, session: session) else { return }
        if LayoutConversion.isOptimistic(op) {
            var next = session
            next.apply(op)
            if next != session { session = next }
        }
        let id = send(daemonOp)
        if LayoutConversion.isReplayable(op) { pending.append((id, .layout(op))) }
    }

    /// Changes the session's projects: shown at once, sent to the daemon.
    public func apply(_ change: ProjectChange) {
        guard let sessionId, supportsProjects else { return }
        projects.apply(change)
        let id = send(LayoutConversion.op(change, sessionId: sessionId))
        pending.append((id, .project(change)))
    }

    /// Shows a saved layout until the daemon's first arrives.
    func seed(_ cached: Session, name: String, projects: HostProjects) {
        guard !hasLayout else { return }
        confirmed = cached
        confirmedProjects = projects
        sessionName = name
        isCached = true
        rebase()
    }

    /// A `LayoutChanged` from the daemon. Layouts older than the one applied are ignored
    /// (`revision`), unless they belong to another session (re-attach).
    func receive(_ layout: SessionLayout) {
        if layout.sessionId == sessionId, let revision, layout.revision < revision { return }
        if supportsFloats, layout.sessionId == sessionId || sessionId == nil,
           floatsRevision.map({ $0 < layout.revision }) ?? true {
            heldLayout = layout
            heldTimeout?.cancel()
            heldTimeout = Task { [weak self, floatsWait] in
                try? await Task.sleep(for: floatsWait)
                guard !Task.isCancelled, let self else { return }
                self.showHeld()
            }
            return
        }
        show(layout)
    }

    private func show(_ layout: SessionLayout) {
        if layout.sessionId != sessionId {
            pending.removeAll()
            projectsRevision = nil
            // Saved projects stay until the daemon's report, which follows its layout, so they
            // never blink out in between.
            if !(isCached && supportsProjects) { confirmedProjects = HostProjects() }
            floatsRevision = nil
            confirmedFloats = []
        }
        isCached = false
        sessionId = layout.sessionId
        sessionName = layout.name
        revision = layout.revision
        confirmed = LayoutConversion.session(layout)
        hasLayout = true
        rebase()
    }

    /// A `Floats` report (sent with every layout): shown together with the layout it follows.
    func receive(_ report: DaemonFloats) {
        if let floatsRevision, report.revision < floatsRevision { return }
        floatsRevision = report.revision
        confirmedFloats = LayoutConversion.floats(report)
        if let held = heldLayout, held.revision <= report.revision {
            heldTimeout?.cancel()
            showHeld()
        } else if report.sessionId == sessionId {
            rebase()
        }
    }

    private func showHeld() {
        guard let held = heldLayout else { return }
        heldLayout = nil
        show(held)
        if let projects = heldProjects {
            heldProjects = nil
            receive(projects)
        }
    }

    /// A `Projects` report (sent with every layout, to owner connections only).
    func receive(_ report: DaemonProjects) {
        if let held = heldLayout, held.sessionId == report.sessionId {
            if heldProjects.map({ $0.revision <= report.revision }) ?? true { heldProjects = report }
            return
        }
        guard report.sessionId == sessionId else { return }
        if let projectsRevision, report.revision < projectsRevision { return }
        projectsRevision = report.revision
        confirmedProjects = LayoutConversion.projects(report)
        rebase()
    }

    /// The daemon answered op `id`: its effect is in the confirmed state now, or it failed and
    /// its optimistic change goes.
    func acknowledge(_ id: UInt64, failed: Bool) {
        if let index = pending.firstIndex(where: { $0.id == id }) { pending.remove(at: index) }
        if failed { rebase() }
    }

    /// The daemon restarted (new epoch): its revisions start over, unanswered ops are lost.
    func resetRevision() {
        revision = nil
        projectsRevision = nil
        floatsRevision = nil
        pending.removeAll()
    }

    /// The attached session no longer exists: no tabs, nothing pending, until a layout of the
    /// session attached next arrives.
    func sessionGone() {
        isCached = false
        pending.removeAll()
        sessionId = nil
        revision = nil
        projectsRevision = nil
        confirmed = Session(tabs: [], activeTabId: nil)
        confirmedProjects = HostProjects()
        rebase()
    }

    /// Drops every optimistic change and shows the daemon's state again.
    func revertToConfirmed() {
        pending.removeAll()
        rebase()
    }

    /// The confirmed state with every unacknowledged change replayed on top.
    private func rebase() {
        var next = confirmed.with(floats: confirmedFloats)
        var nextProjects = confirmedProjects
        for (_, change) in pending {
            switch change {
            case .layout(let op): next.apply(op)
            case .project(let change): nextProjects.apply(change)
            }
        }
        nextProjects.keep(tabs: Set(next.tabs.map(\.id)))
        if next != session { session = next }
        if nextProjects != projects { projects = nextProjects }
    }

    /// What is on screen, for the daemon's stream priorities (`DaemonClient.setView`).
    var view: (focused: UInt64?, visible: [UInt64]) {
        guard let tab = session.activeTab else { return (nil, []) }
        // Windows pinned over every tab show their panes on this one too.
        let pinned = session.floats.filter { $0.pinned && !$0.minimized }.flatMap(\.panes)
        let visible = tab.zoomed.map { [$0] } ?? (tab.root.panes + pinned.filter { !tab.root.contains($0) })
        return (tab.focused.rawValue, visible.map(\.rawValue))
    }
}
