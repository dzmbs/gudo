import DesignSystem
import HostKit
import PaneLayout

extension Workspace {
    /// The sidebar group this workspace's tabs belong to (its host, or this device).
    var groupId: String { hostId ?? HostGroups.localId }

    /// What a pane runs, for its mark: the reported foreground program (daemon `tcgetpgrp`, the
    /// local PTY), else a program its title names (Claude Code's "✳ task", "vim README.md"),
    /// else its shell, else a plain shell.
    func programIdentity(of id: PaneId) -> ProgramIdentity {
        guard let pane = panes[id] else { return .shell }
        if let program = reportedProgram(of: pane) { return ProgramCatalog.identity(process: program) }
        if let titled = ProgramCatalog.identity(title: pane.title) { return titled }
        if let shell = pane.foregroundProgram ?? foregrounds[id]?.program, !shell.isEmpty {
            return ProgramCatalog.identity(process: shell)
        }
        return .shell
    }
}

extension WindowModel {
    /// A pane's program on any group: the agent its host reports wins (Claude Code runs under
    /// `node`), then what the pane's workspace knows.
    func programIdentity(ofPane pane: PaneId, onGroup id: String) -> ProgramIdentity {
        if let agent = agentProgram(ofPane: pane, onGroup: id) {
            let identity = ProgramCatalog.identity(process: agent)
            if !identity.isShell { return identity }
        }
        return workspace(ofGroup: id)?.programIdentity(of: pane) ?? .shell
    }

    /// A tab's program: its focused pane's.
    func programIdentity(of tab: Tab, onGroup id: String) -> ProgramIdentity {
        programIdentity(ofPane: tab.focused, onGroup: id)
    }
}

extension AgentKind {
    /// The agent's mark in the Inbox and the New Agent sheet.
    var identity: ProgramIdentity {
        switch self {
        case .claude: ProgramCatalog.identity(process: "claude")
        case .codex: ProgramCatalog.identity(process: "codex")
        case .other: ProgramIdentity(id: "agent", displayName: title, kind: .agent)
        }
    }
}
