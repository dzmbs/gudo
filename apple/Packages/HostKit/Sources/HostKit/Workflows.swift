import Foundation
import UnnamedCore

/// Workflows (docs/DAEMON.md §5.13): YAML files of named commands with `{{arguments}}` on the
/// host, the pane's repository's first, then the global ones. Kept out of `DaemonWorkspaceAPI`'s
/// list so fakes that do not care need nothing.
nonisolated public protocol DaemonWorkflowAPI: AnyObject, Sendable {
    func workflowList(paneId: UInt64?) async throws -> WorkflowList
    func workflowSave(scope: WorkflowScope, paneId: UInt64?, workflow: WorkflowDraft) async throws -> Workflow
}

extension DaemonClient: DaemonWorkflowAPI {}

extension DaemonWorkspace {
    /// The workflow API of the client of the moment, or `HostError.notConnected`.
    public func workflowClient() throws -> any DaemonWorkflowAPI {
        guard let api = api as? any DaemonWorkflowAPI else { throw HostError.notConnected }
        return api
    }

    /// The workflows `pane` can use (only the global ones for nil). Always asked fresh: the
    /// pane's directory, and so its repository, may have changed since.
    public func workflows(pane: UInt64?) async throws -> WorkflowList {
        try await workflowClient().workflowList(paneId: pane)
    }

    /// Writes a new workflow file on the host (the pane's repository, or the global directory).
    public func saveWorkflow(_ draft: WorkflowDraft, scope: WorkflowScope, pane: UInt64?) async throws -> Workflow {
        try await workflowClient().workflowSave(scope: scope, paneId: pane, workflow: draft)
    }

    /// Calls `handler` with each new revision of the host's workflow files; remove with
    /// `removeObserver`.
    @discardableResult
    public func observeWorkflows(_ handler: @escaping (UInt64) -> Void) -> UUID {
        let id = UUID()
        workflowObservers[id] = handler
        return id
    }
}

extension Workflow {
    /// The command with `values` (by argument name) filled in, shell-quoted where needed
    /// (raw arguments as typed); arguments without a value take their default.
    public func rendered(_ values: [String: String]) -> String {
        workflowRender(
            command: command, arguments: arguments,
            values: values.map { WorkflowValue(name: $0.key, value: $0.value) })
    }

    /// "Repository" or "Global", for badges.
    public var sourceLabel: String { scope == .repo ? "Repository" : "Global" }
}
