import HostKit

nonisolated enum ChatDiffTarget: Hashable, Sendable {
    case turn(String?)
    case tool(item: String, path: String?)
}

nonisolated enum ChatDiffPreview {
    static func files(for target: ChatDiffTarget, rows: [ChatRow]) -> [TimelineFileDiff] {
        rows.flatMap { row -> [TimelineFileDiff] in
            guard case .item(let item) = row.content, case .tool(let tool) = item.body else { return [] }
            switch target {
            case .turn(let turn):
                guard let turn, !turn.isEmpty else { return [] }
                return item.turn == turn ? tool.diff : []
            case .tool(let identifier, let path):
                guard item.id == identifier else { return [] }
                return tool.diff.filter { path == nil || $0.path == path }
            }
        }
    }
}
