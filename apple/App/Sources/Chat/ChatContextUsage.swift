import Foundation
import HostKit

/// How full the agent's context window is. Codex and pi report it (`AgentConfig.context`); for
/// Claude Code it is the last finished turn's input tokens against the model's window.
nonisolated struct ChatContextUsage: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case agent
        case lastTurn
    }

    let used: UInt64
    let limit: UInt64
    let lastOutput: UInt64?
    let source: Source
    /// Rows looked back through for the last turn's end: the meter is drawn with the composer,
    /// so its cost must not grow with the timeline.
    static let rowsSearched = 64

    var fraction: Double { min(1, Double(used) / Double(max(limit, 1))) }
    var percent: Int { Int((fraction * 100).rounded()) }

    /// "48K of 200K".
    var amount: String {
        Self.compact(used) + " of " + Self.compact(limit)
    }

    init(used: UInt64, limit: UInt64, lastOutput: UInt64? = nil, source: Source = .lastTurn) {
        self.used = used
        self.limit = limit
        self.lastOutput = lastOutput
        self.source = source
    }

    init?(reported: AgentContextUsage?, rows: [ChatRow], session: TimelineSession?) {
        if let reported, reported.window > 0 {
            self.init(used: reported.used, limit: reported.window, source: .agent)
            return
        }
        guard let model = session?.model, let limit = Self.window(model: model) else { return nil }
        for row in rows.suffix(Self.rowsSearched).reversed() {
            let end: TimelineTurnEnd?
            switch row.content {
            case .turnFooter(let footer): end = footer.end
            case .item(let item):
                if case .turnEnd(let value) = item.body { end = value } else { end = nil }
            default: end = nil
            }
            if let end, let input = end.inputTokens, input > 0 {
                self.init(used: input, limit: limit, lastOutput: end.outputTokens)
                return
            }
        }
        return nil
    }

    /// Claude Code's context window by model id; Codex and pi report theirs.
    static func window(model: String) -> UInt64? {
        let id = model.lowercased()
        let isClaude = id.hasPrefix("claude-") || ["opus", "sonnet", "haiku"].contains { id.hasPrefix($0) }
        guard isClaude else { return nil }
        return id.contains("[1m]") || id.hasSuffix("-1m") ? 1_000_000 : 200_000
    }

    static func compact(_ tokens: UInt64) -> String {
        tokens.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}
