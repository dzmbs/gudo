import HostKit

/// Conservative retained-value weight, not a resident-memory measurement. String storage is
/// charged twice its UTF-8 size, with allowances for dictionaries, arrays and value records.
nonisolated enum TimelineValueWeight {
    static func of(_ item: TimelineItem) -> Int {
        let actorBytes: Int
        if case .app(let actor) = item.origin {
            actorBytes = 64 + actor.principal.count + actor.device.count
        } else {
            actorBytes = 0
        }
        return 256 + actorBytes + strings(item.id, item.turn, item.parent) + body(item.body)
    }

    private static func strings(_ values: String?...) -> Int {
        values.reduce(0) { $0 + ($1?.utf8.count ?? 0) * 2 }
    }

    private static func body(_ body: TimelineBody) -> Int {
        switch body {
        case .assistant(let value): 128 + strings(value.text)
        case .thinking(let value): 128 + strings(value.text)
        case .notice(let value): 128 + strings(value.kind.wireValue, value.text)
        case .turnEnd: 128
        case .user(let value):
            128 + strings(value.text) + value.attachments.reduce(0) { $0 + 64 + strings($1.path, $1.mediaType) }
        case .plan(let value):
            128 + value.entries.reduce(0) { $0 + 64 + strings($1.text, $1.status.wireValue) }
        case .tool(let value):
            256 + strings(value.kind.wireValue, value.name, value.title, value.input, value.status.wireValue)
                + (value.output.map { 96 + strings($0.handle, $0.preview) } ?? 0)
                + value.diff.reduce(0) { $0 + diff($1) }
        }
    }

    private static func diff(_ value: TimelineFileDiff) -> Int {
        128 + strings(value.path, value.oldPath, value.change.wireValue) + value.hunks.reduce(0) { total, hunk in
            total + 96 + strings(hunk.header) + hunk.lines.reduce(0) { $0 + 48 + strings($1.kind.wireValue, $1.text) }
        }
    }
}
