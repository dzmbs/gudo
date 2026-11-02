import Foundation
import Synchronization
import GudoCore

/// Input assistance for a pane's line editor and smart row: the
/// daemon's prompt state, atomic submit, completion and the blocked agent's options. Panes on a
/// daemon implement it; local and plain-SSH panes don't (the key bar stays in direct mode).
public protocol LineAssist: AnyObject, Sendable {
    /// Starts (or stops) prompt-state pushes for this pane; `onState` runs on a runtime thread.
    func watchPrompt(_ watch: Bool, onState: @escaping @Sendable (PromptState) -> Void) async throws -> PromptState
    /// Clears the shell's line, pastes `text` and (if `run`) presses Return, in one write, if the
    /// pane is still at prompt `promptId`; otherwise throws `AssistError.NotAtPrompt` and writes
    /// nothing.
    func submitLine(promptId: UInt64, text: String, run: Bool) async throws
    /// Candidates for the token at `cursor` (history, paths, git refs, commands).
    func complete(line: String, cursor: UInt32) async throws -> Completions
    /// The options of a blocked agent in this pane, if it is blocked.
    func blockedOptions() async throws -> BlockedPrompt?
    /// Answers a blocked agent's dialog with option `index` (re-checked against `label`).
    func answerBlocked(index: UInt32, label: String) async throws
    /// Signed decision for a hook-held request.
    func decide(requestId: UInt64, optionId: UInt32)
}

/// Routes one client's assist pushes to the panes watching them (a client has one listener).
nonisolated final class AssistRouter: AssistListener {
    private let sinks = Mutex<[UInt64: @Sendable (PromptState) -> Void]>([:])

    /// The router installed on `client`, created on first use.
    static func shared(for client: DaemonClient) -> AssistRouter {
        registry.withLock { routers in
            let key = ObjectIdentifier(client)
            routers = routers.filter { $0.value.client != nil }
            if let router = routers[key]?.router { return router }
            let router = AssistRouter()
            client.setAssistListener(listener: router)
            routers[key] = Entry(client: client, router: router)
            return router
        }
    }

    private struct Entry {
        weak var client: DaemonClient?
        let router: AssistRouter
    }

    private static let registry = Mutex<[ObjectIdentifier: Entry]>([:])

    func set(_ pane: UInt64, _ sink: (@Sendable (PromptState) -> Void)?) {
        sinks.withLock { $0[pane] = sink }
    }

    func onAssistEvent(event: AssistEvent) {
        guard case .prompt(let state) = event else { return }
        let sink = sinks.withLock { $0[state.paneId] }
        sink?(state)
    }
}

extension DaemonPaneBackend: LineAssist {
    private var daemon: DaemonClient {
        get throws {
            guard let client = client as? DaemonClient else { throw AssistError.Failed(message: "no daemon") }
            return client
        }
    }

    public func watchPrompt(_ watch: Bool, onState: @escaping @Sendable (PromptState) -> Void) async throws -> PromptState {
        let client = try daemon
        let router = AssistRouter.shared(for: client)
        router.set(pane.rawValue, watch ? onState : nil)
        return try await client.watchPrompt(paneId: pane.rawValue, watch: watch).prompt
    }

    public func submitLine(promptId: UInt64, text: String, run: Bool) async throws {
        _ = try await daemon.submitLine(paneId: pane.rawValue, promptId: promptId, text: text, run: run)
    }

    public func complete(line: String, cursor: UInt32) async throws -> Completions {
        try await daemon.complete(paneId: pane.rawValue, line: line, cursor: cursor, limit: 24)
    }

    public func blockedOptions() async throws -> BlockedPrompt? {
        try await daemon.blockedOptions(paneId: pane.rawValue)
    }

    public func answerBlocked(index: UInt32, label: String) async throws {
        try await daemon.answerBlocked(paneId: pane.rawValue, index: index, label: label)
    }

    public func decide(requestId: UInt64, optionId: UInt32) {
        client.decide(requestId: requestId, optionId: optionId)
    }
}
