import GudoCore
import HostKit

/// What an empty Chat says. A Claude Code started by hand in a shell has no session at first:
/// Chat finds it from the transcript Claude Code saves, and says so instead of "No messages yet".
/// An agent with no conversation at all, or one stopped on a screen only its terminal can answer
/// (a sign-in, a first-run question), is waiting in Terminal.
nonisolated enum ChatEmptyState: Equatable {
    case opening
    case findingSession
    case waitingInTerminal(agent: AgentKind, reason: String?)
    case empty

    /// `terminalWait` is the host's reason the agent waits in its terminal (`terminalWait(_:)`),
    /// empty when it gave none.
    init(isLoading: Bool, session: TimelineSession?, agent: AgentKind? = nil, terminalWait: String? = nil) {
        if let agent, let terminalWait {
            self = .waitingInTerminal(agent: agent, reason: terminalWait.isEmpty ? nil : terminalWait)
        } else if isLoading { self = .opening }
        else if let session { self = session.nativeSession.isEmpty ? .findingSession : .empty }
        else if let agent { self = .waitingInTerminal(agent: agent, reason: nil) }
        else { self = .empty }
    }

    /// The reason an agent is blocked on something Chat cannot answer: a blocker without choices.
    static func terminalWait(_ state: AgentState?) -> String? {
        guard case .blocked(_, let summary, let options)? = state, options.isEmpty else { return nil }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var title: String {
        switch self {
        case .opening: "Opening Chat…"
        case .findingSession: "Looking for this conversation"
        case .waitingInTerminal(let agent, _): "\(agent.title) is waiting in Terminal"
        case .empty: "No messages yet"
        }
    }

    var detail: String? {
        switch self {
        case .findingSession: "It shows here after the agent's next message. Until then, use Terminal."
        case .waitingInTerminal(_, let reason?):
            "\(reason.hasSuffix(".") ? reason : reason + ".") Answer it in Terminal, then come back here."
        case .waitingInTerminal(_, nil):
            "It hasn't started a conversation yet. It may need you to sign in or answer a question there."
        case .empty: "Messages show here as you and the agent write them."
        case .opening: nil
        }
    }

    var symbol: String {
        if case .waitingInTerminal = self { "apple.terminal" } else { "text.bubble" }
    }

    var offersTerminal: Bool {
        switch self {
        case .findingSession, .waitingInTerminal: true
        case .opening, .empty: false
        }
    }
}
