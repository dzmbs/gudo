import Foundation
import GudoCore

/// The part of `GudoCore.DaemonClient` the data layer uses, so stores and backends can be
/// tested against a fake. Every method returns at once; answers arrive as `ClientEvent`s.
nonisolated public protocol DaemonClientAPI: AnyObject, Sendable {
    func attach(sessionId: UInt64?)
    func op(op: GudoCore.LayoutOp) -> UInt64
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

nonisolated public protocol GeneratedInputClient: AnyObject, Sendable {
    func sendGeneratedInput(paneId: UInt64, data: Data)
}

extension DaemonClient: GeneratedInputClient {}

nonisolated public protocol PaneSizingClient: AnyObject, Sendable {
    func setPaneActivity(paneId: UInt64, activity: PaneActivity)
    func claimPaneSize(paneId: UInt64)
    func setSizePolicy(paneId: UInt64, policy: SizePolicy)
}

extension DaemonClient: PaneSizingClient {}

/// Updating the daemon over its connection (`DaemonClient.upgradeDaemon`), separate from
/// `DaemonClientAPI` so test fakes need not implement it.
nonisolated public protocol DaemonUpgradeAPI: AnyObject, Sendable {
    func upgradeDaemon(path: String, build: String, progress: TransferProgress?) async throws -> DaemonInfo
}

extension DaemonClient: DaemonUpgradeAPI {}

/// A client whose relay settings can change while it runs (`DaemonClient.setRelays`). Not
/// part of `DaemonClientAPI` so test fakes need not implement it.
nonisolated public protocol RelaySettingsClient: AnyObject, Sendable {
    func setRelays(relay: RelayMode, options: ConnectOptions)
}

extension DaemonClient: RelaySettingsClient {}

/// A client that tells the daemon this device's terminal theme (`DaemonClient.setTerminalColors`).
/// Not part of `DaemonClientAPI` so test fakes need not implement it.
nonisolated public protocol TerminalColorsClient: AnyObject, Sendable {
    func setTerminalColors(colors: TerminalColors)
}

extension DaemonClient: TerminalColorsClient {}

/// A client that keeps a live connection across a network change, letting it move to a path
/// that works (`DaemonClient.networkChanged`). Not part of `DaemonClientAPI` so test fakes need
/// not implement it; those redial instead.
nonisolated public protocol NetworkChangeClient: AnyObject, Sendable {
    func networkChanged()
}

extension DaemonClient: NetworkChangeClient {}

nonisolated public protocol ForegroundResumeClient: AnyObject, Sendable {
    func resumeNow()
}

extension DaemonClient: ForegroundResumeClient {}

/// A client that can check its live connection with a ping (`DaemonClient.probe`): one that
/// gets no answer within seconds is dropped and redialled. Not part of `DaemonClientAPI` so
/// test fakes need not implement it.
nonisolated public protocol LivenessClient: AnyObject, Sendable {
    func probe()
}

extension DaemonClient: LivenessClient {}

/// Reopening closed tabs and reading what a pane runs, apart from `DaemonClientAPI` so test
/// fakes need not implement it.
nonisolated public protocol TabHistoryClient: AnyObject, Sendable {
    func reopenTab(sessionId: UInt64, closedPane: UInt64, cwd: String?, name: String) async throws -> ReopenedTab
    func paneAssist(paneId: UInt64) async throws -> PaneAssist
}

extension DaemonClient: TabHistoryClient {}

/// Typing the command a restored pane offers (`ClientEvent.runAgainOffers`), apart from
/// `DaemonClientAPI` so test fakes need not implement it.
nonisolated public protocol RunAgainClient: AnyObject, Sendable {
    func runAgain(offer: RunAgainOffer)
}

extension DaemonClient: RunAgainClient {}

/// The host's terminal limits its panes' mirrors follow (`DaemonClient.imageStorageLimit`),
/// apart from `DaemonClientAPI` so test fakes need not implement it.
nonisolated public protocol TerminalLimitsClient: AnyObject, Sendable {
    func imageStorageLimit() -> UInt64
}

extension DaemonClient: TerminalLimitsClient {}

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

/// Hands events on `delay` after they arrived, in order (`HostsModel.Configuration.linkDelay`).
nonisolated final class DelayedListener: ClientEventListener {
    private let events: AsyncStream<(ContinuousClock.Instant, ClientEvent)>.Continuation
    private let delay: Duration

    init(_ inner: any ClientEventListener, delay: Duration) {
        self.delay = delay
        let (stream, events) = AsyncStream<(ContinuousClock.Instant, ClientEvent)>.makeStream()
        self.events = events
        Task.detached {
            for await (due, event) in stream {
                try? await Task.sleep(until: due)
                inner.onEvent(event: event)
            }
        }
    }

    deinit { events.finish() }

    func onEvent(event: ClientEvent) {
        events.yield((.now + delay, event))
    }
}
