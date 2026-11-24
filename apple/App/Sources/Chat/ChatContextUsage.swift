import Foundation
import HostKit

/// How full the agent's context window is: the tokens its last turn read against the model's
/// window. Known only when the host reported a finished turn's input and the model's window is
/// known.
nonisolated struct ChatContextUsage: Equatable, Sendable {
    let used: UInt64
    let limit: UInt64
    let lastOutput: UInt64?
    /// Rows looked back through for the last turn's end: the meter is drawn with the composer,
    /// so its cost must not grow with the timeline.
    static let rowsSearched = 64

    var fraction: Double { min(1, Double(used) / Double(max(limit, 1))) }
    var percent: Int { Int((fraction * 100).rounded()) }

    /// "48K of 200K".
    var amount: String {
        Self.compact(used) + " of " + Self.compact(limit)
    }

    init(used: UInt64, limit: UInt64, lastOutput: UInt64? = nil) {
        self.used = used
        self.limit = limit
        self.lastOutput = lastOutput
    }

    init?(rows: [ChatRow], session: TimelineSession?) {
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

    /// The context window of the models the agents run, by their ids.
    static func window(model: String) -> UInt64? {
        let id = model.lowercased()
        if id.contains("[1m]") || id.hasSuffix("-1m") { return 1_000_000 }
        if id.hasPrefix("claude-") || ["opus", "sonnet", "haiku"].contains(id) { return 200_000 }
        if id.hasPrefix("gpt-5") || id.contains("codex") { return 272_000 }
        return nil
    }

    static func compact(_ tokens: UInt64) -> String {
        tokens.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}
