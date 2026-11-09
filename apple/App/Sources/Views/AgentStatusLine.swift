import DesignSystem
import Foundation

/// The line under an agent tab's title: what it is, then its state and for how long, so the state
/// is never the part that is cut: "Claude Code · working 12m", "Codex · done 2h ago".
nonisolated struct AgentStatusLine: Equatable, Sendable {
    var kind: String
    var state: AgentState
    var since: Date?
    /// What the agent asks, while it waits for an answer.
    var question: String?

    /// The state and its age alone, for when the whole line does not fit.
    func stateWords(at now: Date) -> String {
        let age = since.map { Self.age(from: $0, to: now) }
        switch state {
        case .blocked: return question.map { "needs you: \($0)" } ?? "needs you"
        case .working: return ["working", age].compactMap(\.self).joined(separator: " ")
        case .done: return age.map { "done \($0) ago" } ?? "done"
        case .idle: return ["idle", age].compactMap(\.self).joined(separator: " ")
        case .error: return "failed"
        case .unknown: return "no contact"
        }
    }

    func text(at now: Date) -> String {
        "\(kind) · \(stateWords(at: now))"
    }

    /// "40s", "12m", "2h", "3d": the largest whole unit.
    static func age(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
