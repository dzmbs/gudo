import DesignSystem
import HostKit
import PaneLayout
import GudoCore

/// What the program in a daemon pane says it is doing, for every status surface. The daemon's
/// agent integration wins (Claude, Codex: it knows approvals); any other program's own OSC 7501
/// report (pi, opencode, scripts, `status_set`) fills in.
struct PaneReport: Hashable {
    var state: DesignSystem.AgentState
    /// Who reports: the agent's kind, else the program's `app` (nil when it gave none).
    var program: String?
    /// The program's own line ("Which framework?"); nil for agent integrations, whose blocked
    /// summary has its own place.
    var message: String?
    /// Percent complete.
    var progress: Int?
    /// What a blocked program waits for.
    var kind: ProgramKind?

    init(state: DesignSystem.AgentState, program: String?, message: String? = nil, progress: Int? = nil, kind: ProgramKind? = nil) {
        self.state = state
        self.program = program
        self.message = message
        self.progress = progress
        self.kind = kind
    }

    /// Nil for a plain shell, and once the pane's process has exited.
    init?(meta: PaneMeta?, program report: ProgramReport?) {
        if meta?.exit != nil { return nil }
        if let agent = meta?.agent {
            self.init(state: DesignSystem.AgentState(agent.state), program: agent.kind)
        } else if let report {
            self.init(
                state: DesignSystem.AgentState(report.state), program: report.app?.nonEmpty,
                message: report.message?.nonEmpty, progress: report.progress.map(Int.init), kind: report.kind)
        } else {
            return nil
        }
    }

    /// The program's words and progress for a status line: "Which framework? · 40%". A blocked
    /// program that said nothing still says what it waits for.
    var detail: String? {
        let words = message ?? (state == .blocked ? kind?.waitingFor : nil)
        let percent = progress.map { "\($0)%" }
        let parts = [words, percent].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension ProgramKind {
    /// What a blocked program waits for, in words.
    var waitingFor: String {
        switch self {
        case .permission: "Wants permission"
        case .question: "Has a question"
        case .auth: "Needs you to sign in"
        }
    }
}

extension DesignSystem.AgentState {
    /// A program's own report (OSC 7501 / `status_set`).
    init(_ state: ProgramState) {
        switch state {
        case .idle: self = .idle
        case .working: self = .working
        case .done: self = .done
        case .blocked: self = .blocked
        case .error: self = .error
        }
    }
}

extension DaemonConnection {
    /// What the program in `pane` reports (`PaneReport`), nil for a plain shell.
    func report(of pane: PaneId) -> PaneReport? {
        PaneReport(meta: meta[pane], program: programs[pane])
    }
}
