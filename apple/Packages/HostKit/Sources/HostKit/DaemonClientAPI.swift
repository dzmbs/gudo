import Foundation
import UnnamedCore

/// The part of `UnnamedCore.DaemonClient` the data layer uses, so stores and backends can be
/// tested against a fake. Every method returns at once; answers arrive as `ClientEvent`s.
nonisolated public protocol DaemonClientAPI: AnyObject, Sendable {
    func attach(sessionId: UInt64?)
    func op(op: UnnamedCore.LayoutOp) -> UInt64
    func subscribe(paneId: UInt64)
    func unsubscribe(paneId: UInt64)
    func setView(focused: UInt64?, visible: [UInt64])
    func resize(paneId: UInt64, size: PaneSize)
    func sendInput(paneId: UInt64, data: Data)
    func sendPaste(paneId: UInt64, text: String)
    func fetchHistory(paneId: UInt64, maxBytes: UInt32) -> Bool
    func decide(requestId: UInt64, optionId: UInt32)
    func reconnect()
    func suspend()
    func paneText(paneId: UInt64) -> String?
}

extension DaemonClient: DaemonClientAPI {}

/// Dials a daemon. The real one is `DaemonClient.connect`; tests pass a fake.
public typealias DaemonDialer = @Sendable (_ ticket: String, _ listener: any ClientEventListener) throws -> any DaemonClientAPI

/// A `ClientEventListener` that forwards to a closure (on the Rust runtime thread).
nonisolated final class ClosureListener: ClientEventListener {
    private let handler: @Sendable (ClientEvent) -> Void

    init(_ handler: @escaping @Sendable (ClientEvent) -> Void) {
        self.handler = handler
    }

    func onEvent(event: ClientEvent) {
        handler(event)
    }
}
