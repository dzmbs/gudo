import DesignSystem
import Foundation
import HostKit
import PaneLayout
import GudoCore

// YAML files on the host. The palette's "/" scope lists the focused pane's (its repository's,
// then the global ones); one with arguments opens the argument form, which types the filled
// command into the pane (Return there runs it) or runs it with ⌘↩. Nothing runs by itself.

/// The panel shown over the window for a workflow.
enum WorkflowPanel: Identifiable {
    /// Fill in a workflow's arguments, then insert or run it in `pane`.
    case arguments(Workflow, pane: PaneId)
    /// Save a command as a new workflow file (New Workflow from Last Command).
    case new(NewWorkflowSeed)

    var id: String {
        switch self {
        case .arguments(let workflow, let pane): "args-\(workflow.id)-\(pane.rawValue)"
        case .new(let seed): "new-\(seed.pane.rawValue)-\(seed.command)"
        }
    }
}

/// Where a new workflow starts: the command and the pane whose repository it may go to.
struct NewWorkflowSeed {
    var command: String
    var pane: PaneId
    /// The pane's repository name, when it is in one.
    var repoName: String?
}

extension WindowModel {
    /// The window's focused pane on a daemon host, and that host's workspace hub.
    var workflowTarget: (hub: DaemonWorkspace, pane: PaneId)? {
        guard let workspace, let daemon = workspace.host as? DaemonConnection, let pane = workspace.focusedPane else { return nil }
        return (daemon.workspace, pane)
    }

    /// Reads the focused pane's workflows into `workflowList` (when the palette opens, and
    /// again on a `workflowsChanged` push while it shows).
    func loadWorkflows() {
        guard let target = workflowTarget else {
            workflowList = nil
            return
        }
        workflowLoad?.cancel()
        workflowLoad = Task { @MainActor [weak self] in
            do {
                let list = try await target.hub.workflows(pane: target.pane.rawValue)
                guard !Task.isCancelled else { return }
                self?.workflowList = list
                self?.workflowPane = target.pane
            } catch {
                guard !Task.isCancelled else { return }
                self?.workflowList = nil
            }
        }
    }

    /// A workflow was chosen: without arguments its command is typed at once, else the
    /// argument form opens.
    func choose(_ workflow: Workflow, in pane: PaneId? = nil) {
        guard let pane = pane ?? workflowPane ?? workspace?.focusedPane else { return }
        if workflow.arguments.isEmpty {
            type(workflow.rendered([:]), into: pane, run: false)
        } else {
            workflowPanel = .arguments(workflow, pane: pane)
        }
    }

    /// Types `command` at the pane's prompt as one paste (bracketed, so a multi-line command
    /// waits too); `run` presses Return after it. The pane gets the keyboard back.
    func type(_ command: String, into paneId: PaneId, run: Bool) {
        guard let pane = workspace?.pane(paneId) else {
            toasts.show(Toast("The pane is gone", systemImage: "exclamationmark.triangle.fill", style: .failure))
            return
        }
        _ = pane.view.surface.paste(command, source: .text, allowUnsafe: true)
        if run { pane.view.send(.press(.enter)) }
        #if os(iOS)
        _ = pane.view.becomeFirstResponder()
        #else
        pane.view.window?.makeFirstResponder(pane.view)
        #endif
    }

    /// New Workflow from Last Command: the focused pane's last finished command (shell
    /// integration) in the save panel.
    func newWorkflowFromLastCommand() {
        guard let target = workflowTarget else {
            toasts.show(Toast("Workflows live on a host running the helper", systemImage: "terminal", style: .neutral))
            return
        }
        Task { @MainActor [weak self] in
            let list = try? await target.hub.commands(pane: target.pane.rawValue)
            let last = list?.commands.last { $0.mark.finished != nil && !($0.mark.command ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            let repo = target.hub.worktree(ofPane: target.pane.rawValue)?.repoName ?? self?.workflowList?.repoName
            self?.workflowPanel = .new(NewWorkflowSeed(command: last?.mark.command ?? "", pane: target.pane, repoName: repo))
        }
    }

    /// Writes the workflow on the host and says where.
    func saveWorkflow(_ draft: WorkflowDraft, scope: WorkflowScope, pane: PaneId) async -> Bool {
        guard let target = workflowTarget else { return false }
        do {
            let saved = try await target.hub.saveWorkflow(draft, scope: scope, pane: pane.rawValue)
            let file = (saved.path as NSString).lastPathComponent
            toasts.show(Toast("Saved \(saved.name) to \(scope == .repo ? "the repository" : "your workflows") (\(file))",
                              systemImage: "checkmark.circle.fill", style: .success))
            loadWorkflows()
            return true
        } catch {
            toasts.show(Toast("Could not save the workflow: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            return false
        }
    }
}

#if os(iOS)
/// What the key bar's workflow buttons stand for, per workspace.
@MainActor
final class KeyBarWorkflowState {
    var workflows: [Workflow] = []
    var observer: UUID?
}

extension Workspace {
    /// Puts the focused pane's repository workflows first in the key bar's snippets row, and
    /// keeps them current: read again when the row is shown and when the host's files change.
    func followWorkflows(of pane: Pane) {
        guard let daemon = host as? DaemonConnection else {
            keyBarWorkflows.workflows = []
            keyBar.workflows = []
            return
        }
        let hub = daemon.workspace
        if keyBarWorkflows.observer == nil {
            keyBarWorkflows.observer = hub.observeWorkflows { [weak self] _ in
                guard let self, let id = focusedPane, let pane = panes[id] else { return }
                followWorkflows(of: pane)
            }
        }
        keyBar.onSnippetsShown = { [weak self, weak pane] in
            guard let self, let pane else { return }
            followWorkflows(of: pane)
        }
        keyBar.onWorkflow = { [weak self, weak pane] id in
            guard let self, let pane, let workflow = keyBarWorkflows.workflows.first(where: { $0.id == id }) else { return }
            ActiveWindow.model(for: self)?.choose(workflow, in: pane.id)
        }
        Task { @MainActor [weak self, weak pane] in
            let list = try? await hub.workflows(pane: pane?.id.rawValue)
            guard let self, let pane, keyBar.target === pane.view else { return }
            keyBarWorkflows.workflows = list?.workflows.filter { $0.scope == .repo } ?? []
            keyBar.workflows = keyBarWorkflows.workflows.map {
                KeyBarWorkflow(id: $0.id, name: $0.name, hasArguments: !$0.arguments.isEmpty)
            }
        }
    }
}
#endif
