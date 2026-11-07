import HostKit

nonisolated enum ChatDiffPreview {
    static func files(matching path: String?, rows: [ChatRow]) -> [TimelineFileDiff] {
        rows.flatMap { row -> [TimelineFileDiff] in
            guard case .item(let item) = row.content, case .tool(let tool) = item.body else { return [] }
            return tool.diff.filter { path == nil || $0.path == path }
        }
    }
}
