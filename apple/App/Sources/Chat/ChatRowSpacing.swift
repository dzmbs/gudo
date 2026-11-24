import CoreGraphics
import DesignSystem
import HostKit

/// The space above a row follows what sits above it: tight inside one reply, open between turns.
nonisolated enum ChatRowSpacing {
    enum Role: Equatable {
        case prompt, reply, work, notice, turnEnd
    }

    static func role(of row: ChatRow) -> Role {
        switch row.content {
        case .markdown, .omitted: return .reply
        case .toolGroup, .turnSummary: return .work
        case .turnFooter: return .turnEnd
        case .showAll(let longText): return longText.role == .known(.user) ? .prompt : .reply
        case .item(let item):
            switch item.body {
            case .user: return .prompt
            case .assistant: return .reply
            case .tool, .thinking, .plan: return .work
            case .notice: return .notice
            case .turnEnd: return .turnEnd
            case .longText(let longText):
                switch longText.role {
                case .known(.user): return .prompt
                case .known(.thinking): return .work
                case .known(.assistant), .unknown: return .reply
                }
            }
        }
    }

    static func top(of row: ChatRow, below previous: ChatRow?) -> CGFloat {
        guard let previous else { return 0 }
        let above = role(of: previous), below = role(of: row)
        if previous.id.item == row.id.item { return above == .prompt ? DS.Space.xs : DS.Space.m }
        switch (above, below) {
        case (.prompt, .prompt): return DS.Space.xs
        case (.prompt, _): return DS.Space.l
        case (_, .prompt): return DS.Space.xxxl
        case (.work, .work): return 0
        case (.reply, .work), (.work, .reply), (_, .turnEnd): return DS.Space.s
        default: return DS.Space.l
        }
    }
}
