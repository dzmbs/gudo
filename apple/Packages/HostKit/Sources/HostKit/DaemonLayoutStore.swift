import Observation
import PaneLayout
import UnnamedCore

/// A `LayoutStore` whose source of truth is the daemon (docs/DAEMON.md §1): `apply` sends the
/// op to the daemon and `session` is whatever `LayoutChanged` last said. Ops that only move
/// focus or ratios are applied locally at once too (the daemon's answer, one round trip later,
/// replaces them), so focus and divider drags never wait on the network; ops that create or
/// end panes wait for the daemon, which allocates the ids.
@MainActor
@Observable
public final class DaemonLayoutStore: LayoutStore {
    public private(set) var session: Session
    /// The attached daemon session, once known.
    public private(set) var sessionId: UInt64?
    /// Whether a layout has arrived since attaching (views show "Connecting…" until then).
    public private(set) var hasLayout = false
    /// The daemon session's name.
    public private(set) var sessionName = ""

    @ObservationIgnored private var revision: UInt64?
    @ObservationIgnored private var confirmed: Session
    @ObservationIgnored private let send: (UnnamedCore.LayoutOp) -> UInt64

    /// `send` delivers an op to the daemon and returns its id (`DaemonClient.op`).
    public init(send: @escaping (UnnamedCore.LayoutOp) -> UInt64) {
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
        _ = send(daemonOp)
    }

    /// A `LayoutChanged` from the daemon. Layouts older than the one applied are ignored
    /// (`revision`), unless they belong to another session (re-attach).
    func receive(_ layout: SessionLayout) {
        if layout.sessionId == sessionId, let revision, layout.revision < revision { return }
        sessionId = layout.sessionId
        sessionName = layout.name
        revision = layout.revision
        confirmed = LayoutConversion.session(layout)
        hasLayout = true
        if confirmed != session { session = confirmed }
    }

    /// The daemon restarted (new epoch): its revisions start over.
    func resetRevision() {
        revision = nil
    }

    /// An op failed: drop optimistic changes and show the daemon's layout again.
    func revertToConfirmed() {
        if confirmed != session { session = confirmed }
    }

    /// What is on screen, for the daemon's stream priorities (`DaemonClient.setView`).
    var view: (focused: UInt64?, visible: [UInt64]) {
        guard let tab = session.activeTab else { return (nil, []) }
        let visible = tab.zoomed.map { [$0] } ?? tab.root.panes
        return (tab.focused.rawValue, visible.map(\.rawValue))
    }
}
