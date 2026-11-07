import HostKit

nonisolated enum ChatDiffTarget: Hashable, Sendable {
    case turn(String?)
    case tool(item: String, path: String?)
}

nonisolated struct ChatToolDiff: Sendable {
    let item: String
    let files: [TimelineFileDiff]
}

nonisolated enum ChatDiffPreview {
    static func files(for target: ChatDiffTarget, rows: [ChatRow]) -> [TimelineFileDiff] {
        groups(for: target, rows: rows).flatMap(\.files)
    }

    static func groups(for target: ChatDiffTarget, rows: [ChatRow]) -> [ChatToolDiff] {
        rows.compactMap { row in
            guard case .item(let item) = row.content, case .tool(let tool) = item.body else { return nil }
            let files: [TimelineFileDiff]
            switch target {
            case .turn(let turn):
                guard let turn, !turn.isEmpty, item.turn == turn else { return nil }
                files = tool.diff
            case .tool(let identifier, let path):
                guard item.id == identifier else { return nil }
                files = tool.diff.filter { path == nil || $0.path == path }
            }
            return ChatToolDiff(item: item.id, files: files)
        }
    }
}
