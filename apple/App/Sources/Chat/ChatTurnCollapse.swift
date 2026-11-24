import HostKit

/// What a finished turn did before its reply, folded into one line under the prompt.
nonisolated struct ChatTurnSummary: Equatable, Sendable {
    let tools: [TimelineItem]
    let messages: Int

    var label: String {
        let tools = tools.compactMap { item -> TimelineTool? in
            if case .tool(let tool) = item.body { tool } else { nil }
        }
        var parts: [String] = []
        if !tools.isEmpty { parts.append(ChatToolGroups.actions(tools)) }
        if messages > 0 { parts.append(messages == 1 ? "1 message" : "\(messages) messages") }
        let text = parts.joined(separator: ", ")
        let sentence = text.prefix(1).uppercased() + text.dropFirst()
        return sentence.isEmpty ? "Details" : sentence
    }

    /// The label, then shorter forms for a line too narrow for it, as a tool group shortens.
    var shortenedLabels: [String] {
        let tools = tools.compactMap { item -> TimelineTool? in
            if case .tool(let tool) = item.body { tool } else { nil }
        }
        return [label] + ChatToolGroups.shortenedActions(tools).dropFirst()
    }

    var outcome: String? {
        ChatToolGroups.outcome(tools.compactMap { item in
            if case .tool(let tool) = item.body { tool } else { nil }
        })
    }
}

/// Under a finished turn's reply: Copy for the reply, how long the turn took and its changes.
nonisolated struct ChatTurnFooter: Equatable, Sendable {
    let turn: String?
    /// The final reply's Markdown, one entry per message.
    let replies: [String]
    let end: TimelineTurnEnd?

    var markdown: String { replies.joined(separator: "\n\n") }
}

/// Folds each finished turn: everything the agent did before its last reply collapses into one
/// line under the prompt, the reply stays, and a footer under it offers Copy. A turn folds once
/// it ended (its turn end arrived, or a later prompt), and only when it did work before replying.
nonisolated enum ChatTurnCollapse {
    private static let summaryMarker = "\u{1}turn:"
    private static let footerMarker = "\u{1}end:"

    static func isSummary(_ identifier: ChatRowID) -> Bool { identifier.item.hasPrefix(summaryMarker) }

    static func fold(_ rows: [ChatRow], expanded: Set<ChatRowID>, collapses: Bool,
                     reply: (String) -> String?, previous: [ChatRowID: ChatRow] = [:]) -> [ChatRow] {
        var folded: [ChatRow] = []
        folded.reserveCapacity(rows.count + 4)
        var start = 0
        while start < rows.count {
            var hostEnd = start
            while hostEnd < rows.count, ChatRowSpacing.role(of: rows[hostEnd]) == .prompt { hostEnd += 1 }
            var end = hostEnd
            while end < rows.count, ChatRowSpacing.role(of: rows[end]) != .prompt { end += 1 }
            folded.append(contentsOf: rows[start..<hostEnd])
            let body = rows[hostEnd..<end]
            let closed = end < rows.count || body.contains(where: isTurnEnd)
            if closed {
                append(body, host: hostEnd > start ? rows[start] : nil, expanded: expanded, collapses: collapses,
                       reply: reply, previous: previous, to: &folded)
            } else {
                folded.append(contentsOf: body)
            }
            start = end
        }
        return folded
    }

    private static func append(_ body: ArraySlice<ChatRow>, host: ChatRow?, expanded: Set<ChatRowID>, collapses: Bool,
                               reply: (String) -> String?, previous: [ChatRowID: ChatRow], to folded: inout [ChatRow]) {
        guard let last = body.lastIndex(where: { ChatRowSpacing.role(of: $0) == .reply }) else {
            folded.append(contentsOf: body)
            return
        }
        var replyStart = last
        while replyStart > body.startIndex, ChatRowSpacing.role(of: body[replyStart - 1]) == .reply { replyStart -= 1 }
        let before = body[body.startIndex..<replyStart]
        var tools: [TimelineItem] = []
        var messages: Set<String> = []
        for row in before {
            guard case .item(let item) = row.content else {
                if ChatRowSpacing.role(of: row) == .reply { messages.insert(row.id.item) }
                continue
            }
            if case .tool = item.body { tools.append(item) }
            else if ChatRowSpacing.role(of: row) == .reply { messages.insert(item.id) }
        }
        if collapses, let host, !tools.isEmpty || !messages.isEmpty {
            let identifier = ChatRowID(item: summaryMarker + host.id.item, part: 0)
            let summary = ChatTurnSummary(tools: tools, messages: messages.count)
            folded.append(derived(identifier, turn: before.first?.turn ?? host.turn, content: .turnSummary(summary), previous: previous))
            if expanded.contains(identifier) { folded.append(contentsOf: before) }
            else { folded.append(contentsOf: before.filter(staysVisible)) }
        } else {
            folded.append(contentsOf: before)
        }
        let replyRows = body[replyStart...last]
        folded.append(contentsOf: replyRows)
        var replyItems: [String] = []
        for row in replyRows where replyItems.last != row.id.item { replyItems.append(row.id.item) }
        let replies = replyItems.compactMap(reply)
        let rest = body[(last + 1)...]
        let endRow = rest.first(where: isTurnEnd)
        guard !replies.isEmpty else {
            folded.append(contentsOf: rest)
            return
        }
        var end: TimelineTurnEnd?
        if case .item(let item) = endRow?.content, case .turnEnd(let value) = item.body { end = value }
        let turn = replyRows.first?.turn
        let identifier = ChatRowID(item: footerMarker + (turn ?? replyItems[0]), part: 0)
        let footer = derived(identifier, turn: turn, content: .turnFooter(ChatTurnFooter(turn: turn, replies: replies, end: end)),
                             previous: previous)
        if endRow == nil { folded.append(footer) }
        for row in rest { folded.append(isTurnEnd(row) ? footer : row) }
    }

    private static func derived(_ identifier: ChatRowID, turn: String?, content: ChatRow.Content,
                                previous: [ChatRowID: ChatRow]) -> ChatRow {
        let revision: UInt32
        if let old = previous[identifier] { revision = old.content == content ? old.revision : old.revision &+ 1 }
        else { revision = 1 }
        return ChatRow(id: identifier, revision: revision, turn: turn, content: content)
    }

    /// A plan stays in view in a folded turn: it is where the work stands, not how it went.
    private static func staysVisible(_ row: ChatRow) -> Bool {
        guard case .item(let item) = row.content else { return false }
        if case .plan = item.body { return true }
        return false
    }

    private static func isTurnEnd(_ row: ChatRow) -> Bool {
        guard case .item(let item) = row.content, case .turnEnd = item.body else { return false }
        return true
    }
}
