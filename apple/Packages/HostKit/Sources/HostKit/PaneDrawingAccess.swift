import Foundation
import GudoCore

/// What drawing in a pane (docs/DAEMON.md §7.11) needs from a daemon pane: the client for
/// artifacts, placements and send-to-agent, and the output offsets its terminal applies (row
/// anchors are named by offset). Local and plain-SSH panes have no daemon and no drawing.
extension DaemonPaneBackend {
    /// The daemon client behind this pane (nil only for test fakes).
    public var daemonClient: DaemonClient? { client as? DaemonClient }

    public var paneId: UInt64 { pane.rawValue }

    /// `callback(seq, snapshot)` runs right after the pane's terminal applied output up to `seq`
    /// (`snapshot`: a snapshot taken at `seq` replaced its state), on the connection's thread,
    /// in stream order. One callback per `observer` (drawing, command marks); nil stops it.
    public func onOutputApplied(
        observer: String = "drawing", _ callback: (@Sendable (_ seq: UInt64, _ snapshot: Bool) -> Void)?
    ) {
        router.onApplied(pane.rawValue, tap: tap, observer: observer, callback)
    }
}
