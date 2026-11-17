import HostKit

nonisolated struct ChatToolGroup: Equatable, Sendable {
    let tools: [TimelineItem]
    let summary: String
    let additions: UInt64
    let deletions: UInt64
}

/// Consecutive tool calls read as one quiet line, "Ran 3 commands, read 2 files (1 failed)",
/// that expands to the calls themselves. A call still running stays visible below its line.
nonisolated enum ChatToolGroups {
    private static let marker = "\u{1}tools:"

    static func isGroup(_ identifier: ChatRowID) -> Bool { identifier.item.hasPrefix(marker) }

    static func fold(_ rows: [ChatRow], expanded: Set<ChatRowID>, previous: [ChatRowID: ChatRow] = [:]) -> [ChatRow] {
        var folded: [ChatRow] = []
        folded.reserveCapacity(rows.count)
        var run: [ChatRow] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            let tools = run.compactMap(tool)
            guard tools.count > 1, let first = run.first else { folded.append(contentsOf: run); return }
            let identifier = ChatRowID(item: marker + first.id.item, part: 0)
            let isExpanded = expanded.contains(identifier)
            let live = run.filter { tool($0)?.status == .known(.running) }
            let finished = run.compactMap { row -> TimelineItem? in
                guard case .item(let item) = row.content, case .tool(let tool) = item.body,
                      isExpanded || tool.status != .known(.running) else { return nil }
                return item
            }
            guard !finished.isEmpty else { folded.append(contentsOf: run); return }
            let group = ChatToolGroup(tools: finished, summary: summary(finished.compactMap(toolBody)),
                                      additions: finished.compactMap(toolBody).reduce(0) { $0 + $1.diff.reduce(0) { $0 + UInt64($1.additions) } },
                                      deletions: finished.compactMap(toolBody).reduce(0) { $0 + $1.diff.reduce(0) { $0 + UInt64($1.deletions) } })
            let content = ChatRow.Content.toolGroup(group)
            let revision: UInt32
            if let old = previous[identifier] { revision = old.content == content ? old.revision : old.revision &+ 1 }
            else { revision = 1 }
            folded.append(ChatRow(id: identifier, revision: revision, turn: first.turn, content: content))
            folded.append(contentsOf: isExpanded ? run : live)
        }
        for row in rows {
            if joinsRun(row) { run.append(row) } else { flush(); folded.append(row) }
        }
        flush()
        return folded
    }

    static func summary(_ tools: [TimelineTool]) -> String {
        let text = actions(tools)
        return outcome(tools).map { text + " (" + $0 + ")" } ?? text
    }

    /// What the calls did, "Ran 3 commands, read 2 files".
    static func actions(_ tools: [TimelineTool]) -> String {
        sentence(phrases(tools))
    }

    /// The actions, then shorter forms for a line too narrow for them: whole phrases dropped from
    /// the end and the calls they covered counted, "Ran 3 commands, read a file +1".
    static func shortenedActions(_ tools: [TimelineTool]) -> [String] {
        let phrases = phrases(tools)
        guard !phrases.isEmpty else { return [""] }
        return (1...phrases.count).reversed().map { kept in
            let left = phrases.dropFirst(kept).reduce(0) { $0 + $1.count }
            return sentence(phrases.prefix(kept)) + (left > 0 ? " +\(left)" : "")
        }
    }

    private static func phrases(_ tools: [TimelineTool]) -> [(phrase: Phrase, count: Int)] {
        var order: [Phrase] = []
        var counts: [Phrase: Int] = [:]
        for tool in tools {
            let phrase = Phrase(tool.kind)
            if counts[phrase] == nil { order.append(phrase) }
            counts[phrase, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    private static func sentence(_ phrases: some Collection<(phrase: Phrase, count: Int)>) -> String {
        let text = phrases.map { $0.phrase.words($0.count) }.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The calls that did not finish, "1 failed, 1 denied", or nil when every one did.
    static func outcome(_ tools: [TimelineTool]) -> String? {
        var outcomes: [String] = []
        for (status, word) in [(TimelineToolStatusTag.failed, "failed"), (.denied, "denied"), (.interrupted, "interrupted")] {
            let count = tools.count(where: { $0.status == .known(status) })
            if count > 0 { outcomes.append("\(count) \(word)") }
        }
        return outcomes.isEmpty ? nil : outcomes.joined(separator: ", ")
    }

    private static func joinsRun(_ row: ChatRow) -> Bool {
        guard row.imagePath == nil, case .item(let item) = row.content else { return false }
        switch item.body {
        case .tool, .thinking: return true
        default: return false
        }
    }

    private static func tool(_ row: ChatRow) -> TimelineTool? {
        guard case .item(let item) = row.content else { return nil }
        return toolBody(item)
    }

    private static func toolBody(_ item: TimelineItem) -> TimelineTool? {
        if case .tool(let tool) = item.body { return tool }
        return nil
    }

    private enum Phrase: Hashable {
        case command, read, search, edit, write, fetch, webSearch, subagent, tool

        init(_ kind: TimelineToolKind) {
            switch kind {
            case .known(.shell): self = .command
            case .known(.read): self = .read
            case .known(.search): self = .search
            case .known(.edit): self = .edit
            case .known(.write): self = .write
            case .known(.fetch): self = .fetch
            case .known(.webSearch): self = .webSearch
            case .known(.task): self = .subagent
            case .known(.mcp), .known(.other), .unknown: self = .tool
            }
        }

        func words(_ count: Int) -> String {
            let one = count == 1
            switch self {
            case .command: return one ? "ran a command" : "ran \(count) commands"
            case .read: return one ? "read a file" : "read \(count) files"
            case .search: return one ? "searched once" : "searched \(count) times"
            case .edit: return one ? "made an edit" : "made \(count) edits"
            case .write: return one ? "wrote a file" : "wrote \(count) files"
            case .fetch: return one ? "fetched a page" : "fetched \(count) pages"
            case .webSearch: return one ? "searched the web" : "searched the web \(count) times"
            case .subagent: return one ? "ran a subagent" : "ran \(count) subagents"
            case .tool: return one ? "used a tool" : "used \(count) tools"
            }
        }
    }
}
