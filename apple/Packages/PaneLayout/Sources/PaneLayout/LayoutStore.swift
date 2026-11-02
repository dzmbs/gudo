import Observation

/// Owns a session's layout. Views read `session` (observed) and change it only through `apply`,
/// so the source of truth can move to the daemon without touching the UI: a daemon-backed store
/// sends the op over the wire and publishes the session the daemon answers with.
@MainActor
public protocol LayoutStore: AnyObject, Observable {
    var session: Session { get }
    func apply(_ op: LayoutOp)
}

@MainActor
@Observable
public final class LocalLayoutStore: LayoutStore {
    public private(set) var session: Session

    public init(session: Session = Session()) {
        self.session = session
    }

    public func apply(_ op: LayoutOp) {
        var next = session
        next.apply(op)
        // Ops that change nothing (re-focusing the focused pane) must not invalidate observers.
        if next != session { session = next }
    }
}
