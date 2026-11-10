import Foundation
import Synchronization
@testable import HostKit
import TerminalCore
import GudoCore

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A `DaemonClientAPI` that records calls; tests push events through `listener`.
nonisolated final class FakeClient: DaemonClientAPI, GeneratedInputClient, PaneSizingClient, RunAgainClient {
    enum Call: Equatable {
        case attach(UInt64?), op(GudoCore.LayoutOp), subscribe(UInt64), unsubscribe(UInt64)
        case setView(UInt64?, [UInt64]), resize(UInt64, PaneSize), input(UInt64, Data), paste(UInt64, String)
        case generatedInput(UInt64, Data)
        case activity(UInt64, PaneActivity), claimSize(UInt64), sizePolicy(UInt64, SizePolicy)
        case fetchHistory(UInt64), decide(UInt64, UInt32), reconnect, suspend, probe
        case runAgain(UInt64, String)
        case lowDataMode(Bool)
    }

    let listener: any ClientEventListener
    private let recorded = Mutex<[Call]>([])
    private let nextOp = Atomic<UInt64>(1)

    init(listener: any ClientEventListener) {
        self.listener = listener
    }

    var calls: [Call] { recorded.withLock { $0 } }
    func clear() { recorded.withLock { $0.removeAll() } }
    private func record(_ call: Call) { recorded.withLock { $0.append(call) } }

    func send(_ event: ClientEvent) { listener.onEvent(event: event) }

    func attach(sessionId: UInt64?) { record(.attach(sessionId)) }
    func op(op: GudoCore.LayoutOp) -> UInt64 {
        record(.op(op))
        return nextOp.add(1, ordering: .relaxed).oldValue
    }
    func subscribe(paneId: UInt64) { record(.subscribe(paneId)) }
    func unsubscribe(paneId: UInt64) { record(.unsubscribe(paneId)) }
    func setView(focused: UInt64?, visible: [UInt64]) { record(.setView(focused, visible)) }
    func resize(paneId: UInt64, size: PaneSize) { record(.resize(paneId, size)) }
    func setPaneActivity(paneId: UInt64, activity: PaneActivity) { record(.activity(paneId, activity)) }
    func claimPaneSize(paneId: UInt64) { record(.claimSize(paneId)) }
    func runAgain(offer: RunAgainOffer) { record(.runAgain(offer.paneId, offer.command)) }
    func setSizePolicy(paneId: UInt64, policy: SizePolicy) { record(.sizePolicy(paneId, policy)) }
    func sendInput(paneId: UInt64, data: Data) { record(.input(paneId, data)) }
    func sendGeneratedInput(paneId: UInt64, data: Data) { record(.generatedInput(paneId, data)) }
    func sendPaste(paneId: UInt64, text: String) { record(.paste(paneId, text)) }
    func fetchHistory(paneId: UInt64, maxBytes: UInt32) -> Bool {
        record(.fetchHistory(paneId))
        return true
    }
    func decide(requestId: UInt64, optionId: UInt32) { record(.decide(requestId, optionId)) }
    func reconnect() { record(.reconnect) }
    func suspend() { record(.suspend) }
    func paneText(paneId: UInt64) -> String? { nil }
}

extension FakeClient: LivenessClient {
    func probe() { record(.probe) }
}

extension FakeClient: LowDataModeClient {
    func setLowDataMode(lowDataMode: Bool) { record(.lowDataMode(lowDataMode)) }
}

extension FakeClient: DaemonUpgradeAPI {
    /// Installs at once and answers with the build it was sent, as a daemon does before it
    /// restarts.
    func upgradeDaemon(path: String, build: String, progress: TransferProgress?) async throws -> DaemonInfo {
        daemonInfo(build: build)
    }
}

/// Collects a backend's events.
nonisolated final class EventSink: Sendable {
    private let events = Mutex<[PaneEvent]>([])
    var all: [PaneEvent] { events.withLock { $0 } }
    var handler: @Sendable (PaneEvent) -> Void { { event in self.events.withLock { $0.append(event) } } }

    var output: String {
        all.reduce(into: "") { text, event in
            if case .output(let data) = event { text += String(decoding: data, as: UTF8.self) }
        }
    }

    var lastConnection: PaneConnection? {
        all.reversed().lazy.compactMap { if case .connection(let connection) = $0 { connection } else { nil } }.first
    }
}

/// Polls until `condition` holds (the main-actor event pump runs in between).
@MainActor
func eventually(
    _ what: String, timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestError("timed out waiting for \(what)")
}

/// A layout: one tab (id 10) with panes 1 | (2 / 3), pane 3 focused.
func sampleLayout(revision: UInt64 = 1, focused: UInt64 = 3, zoomed: UInt64? = nil) -> SessionLayout {
    SessionLayout(
        sessionId: 7, name: "main", revision: revision, activeTab: 10,
        tabs: [
            TabLayout(
                tabId: 10, name: "",
                nodes: [
                    .split(axis: .horizontal, ratio: 0.5, first: 1, second: 2),
                    .leaf(paneId: 1),
                    .split(axis: .vertical, ratio: 0.25, first: 3, second: 4),
                    .leaf(paneId: 2),
                    .leaf(paneId: 3),
                ],
                focused: focused, zoomed: zoomed),
        ])
}

/// Collects prediction updates.
nonisolated final class PredictionSink: Sendable {
    private let updates = Mutex<[PredictionUpdate]>([])
    var all: [PredictionUpdate] { updates.withLock { $0 } }
    var handler: @Sendable (PredictionUpdate) -> Void { { update in self.updates.withLock { $0.append(update) } } }
}
