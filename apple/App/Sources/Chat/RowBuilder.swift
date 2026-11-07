// Incremental partitioning adapted from OpenAI Codex, Copyright 2025 OpenAI, Apache-2.0.
// Modified for native block rows and Swift Markdown source ranges.
import Foundation
import HostKit
import Markdown

nonisolated enum ChatRenderLimits {
    static let rowsPerMessage = 3_000
    static let markdownBytes = 256 * 1_024
    static let omittedMessage = "This message is too large for Chat. Open Terminal to read it."
}

nonisolated enum ChatCacheLimits {
    static let entries = 500
    static let paragraphProfiles = 8
    static let bytes = 4 * 1_024 * 1_024
}

nonisolated struct ChatRowID: Hashable, Sendable {
    let item: String
    let part: Int

    var storageKey: String { "\(item.utf8.count):\(item):\(part)" }
}

nonisolated struct ChatRow: Equatable, Sendable, Identifiable {
    let id: ChatRowID
    let revision: UInt32
    let turn: String?
    let content: Content
    var preview: String?
    var planPreview: TimelinePlan?

    enum Content: Equatable, Sendable {
        case markdown(ChatMarkdownBlock)
        case item(TimelineItem)
        case omitted
    }
}

nonisolated struct ChatMarkdownBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph, heading(Int), quote, list, code(String?), table, separator, plain
    }

    let kind: Kind
    let source: String
    var text: AttributedString
    var list: [ChatListLine] = []
    var table: [[AttributedString]] = []
    var code: ChatCodeSnippet?
    var hasOmittedContent = false
}

nonisolated struct ChatCodeSnippet: Equatable, Sendable {
    let text: String
    let preview: String
    let lineCount: Int
    let visibleLineCount: Int
    let isTruncated: Bool
}

nonisolated struct ChatListLine: Equatable, Sendable {
    let depth: Int
    let marker: String
    let text: AttributedString
}

nonisolated private struct MarkdownSource {
    let whole: String
    let bytes: [UInt8]
    let lineStarts: [Int]

    init(_ text: String) {
        whole = text
        bytes = Array(text.utf8)
        var starts = [0]
        for (index, byte) in bytes.enumerated() where byte == 10 { starts.append(index + 1) }
        lineStarts = starts
    }

    func text(in range: SourceRange?) -> String? {
        guard let range, let lower = offset(range.lowerBound), let upper = offset(range.upperBound), lower <= upper else { return nil }
        return String(bytes: bytes[lower..<upper], encoding: .utf8)
    }

    func blockStart(_ range: SourceRange?) -> Int? {
        guard let line = range?.lowerBound.line, lineStarts.indices.contains(line - 1) else { return nil }
        return lineStarts[line - 1]
    }

    private func offset(_ location: SourceLocation) -> Int? {
        guard lineStarts.indices.contains(location.line - 1), location.column > 0 else { return nil }
        let offset = lineStarts[location.line - 1] + location.column - 1
        let end = location.line < lineStarts.count ? lineStarts[location.line] - 1 : bytes.count
        return offset <= end ? offset : nil
    }
}

actor RowBuilder {
    private struct MarkdownPartition {
        let source: String
        let blocks: [ChatMarkdownBlock]
        let stableBytes: Int
        let stableBlocks: Int
    }

    private struct Entry {
        let revision: UInt32
        let rows: [ChatRow]
        let partition: MarkdownPartition?
    }

    private let cache = BoundedLRU<String, Entry>(
        capacity: ChatCacheLimits.entries, byteLimit: ChatCacheLimits.bytes, unitLimit: ChatCacheLimits.entries
    )
    private(set) var parseCount = 0
    private(set) var parsedBytes = 0

    func rows(for item: TimelineItem) -> [ChatRow] {
        let previous = cache.value(for: item.id)
        if let previous, previous.revision == item.revision { return previous.rows }
        let rows: [ChatRow]
        var bytes = TimelineValueWeight.of(item)
        var partition: MarkdownPartition?
        if case .assistant(let assistant) = item.body {
            guard let rendered = markdown(assistant.text, after: previous?.partition) else {
                cache.remove(item.id)
                return [ChatRow(id: ChatRowID(item: item.id, part: 0), revision: item.revision,
                                turn: item.turn, content: .omitted)]
            }
            partition = rendered
            let blocks = rendered.blocks
            let previousRows = previous?.rows ?? []
            rows = blocks.enumerated().map { index, block in
                let content = ChatRow.Content.markdown(block)
                if previousRows.indices.contains(index), previousRows[index].turn == item.turn,
                   previousRows[index].content == content { return previousRows[index] }
                return ChatRow(id: ChatRowID(item: item.id, part: index), revision: item.revision,
                               turn: item.turn, content: content)
            }
            // Preserve ID/turn/actor charges as well as copied Markdown buffers and row metadata.
            bytes += assistant.text.utf8.count * 2 + rows.count * 512 + 256
        } else { rows = [plainRow(item)] }
        cache.insert(Entry(revision: item.revision, rows: rows, partition: partition), for: item.id,
                     cost: LRUCost(bytes: bytes, units: rows.count))
        return rows
    }

    func rows(for items: [TimelineItem]) -> [String: [ChatRow]] {
        var result: [String: [ChatRow]] = [:]
        for item in items { result[item.id] = rows(for: item) }
        return result
    }

    func remove(_ identifiers: Set<String>) {
        for identifier in identifiers { cache.remove(identifier) }
    }

    func clear() { cache.removeAll() }

    var cacheSize: Int { cache.count }
    var cacheRowCount: Int { cache.cost.units }
    var cacheBytes: Int { cache.cost.bytes }

    private func plainRow(_ item: TimelineItem) -> ChatRow {
        let text: String?
        switch item.body {
        case .user(let user): text = user.text
        case .thinking(let thinking): text = thinking.text
        case .notice(let notice): text = notice.text
        default: text = nil
        }
        let preview = text.flatMap { $0.utf8.count > 4_096 ? prefix($0, bytes: 4_096) : nil }
        var planPreview: TimelinePlan?
        if case .plan(let plan) = item.body,
           plan.entries.count > 20 || plan.entries.contains(where: { $0.text.utf8.count > 512 }) {
            var limited = plan
            limited.entries = plan.entries.prefix(20).map { entry in
                var limited = entry
                limited.text = prefix(entry.text, bytes: 512)
                return limited
            }
            planPreview = limited
        }
        return ChatRow(id: ChatRowID(item: item.id, part: 0), revision: item.revision, turn: item.turn,
                       content: .item(item), preview: preview, planPreview: planPreview)
    }

    private func prefix(_ text: String, bytes: Int) -> String {
        var prefix = Array(text.utf8.prefix(bytes))
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return String(decoding: prefix, as: UTF8.self)
    }

    private func markdown(_ source: String, after previous: MarkdownPartition?) -> MarkdownPartition? {
        guard source.utf8.count <= ChatRenderLimits.markdownBytes else { return nil }
        if let previous, previous.source == source { return previous }
        var retained: [ChatMarkdownBlock] = []
        var offset = 0
        var pending = source
        // Reference definitions can affect earlier blocks. Their conservative fallback also
        // catches escaped/code-like definitions without duplicating CommonMark's grammar.
        if let previous, !source.contains("]:"), source.utf8.starts(with: previous.source.utf8),
           let byteIndex = source.utf8.index(source.utf8.startIndex, offsetBy: previous.stableBytes, limitedBy: source.utf8.endIndex),
           let index = String.Index(byteIndex, within: source) {
            retained = Array(previous.blocks.prefix(previous.stableBlocks))
            offset = previous.stableBytes
            pending = String(source[index...])
        }
        parseCount += 1
        parsedBytes += pending.utf8.count
        let document = Document(parsing: pending)
        let original = MarkdownSource(pending)
        var blocks = retained
        var stableBytes = offset
        var stableBlocks = retained.count
        // cmark can temporarily split a partial table row into a following paragraph.
        // Retain one extra block until the final source line is complete.
        let mutableCount = pending.hasSuffix("\n") || pending.hasSuffix("\r") ? 1 : 2
        let boundary = max(0, document.childCount - mutableCount)
        for (index, markup) in document.children.enumerated() {
            if index == boundary, let start = original.blockStart(markup.range) {
                stableBytes = offset + start
                stableBlocks = blocks.count
            }
            let rows = blockRows(markup, original: original)
            guard rows.count <= ChatRenderLimits.rowsPerMessage - blocks.count else { return nil }
            blocks.append(contentsOf: rows)
        }
        return MarkdownPartition(source: source, blocks: blocks, stableBytes: stableBytes, stableBlocks: stableBlocks)
    }

    private func blockRows(_ markup: any Markup, original: MarkdownSource) -> [ChatMarkdownBlock] {
        let rendered = block(markup, source: original.text(in: markup.range) ?? original.whole, original: original)
        if rendered.kind == .list, rendered.list.count > 20 {
            return stride(from: 0, to: rendered.list.count, by: 20).map { start in
                var chunk = rendered
                chunk.list = Array(rendered.list[start..<min(start + 20, rendered.list.count)])
                return chunk
            }
        }
        switch rendered.kind {
        case .paragraph, .heading, .quote, .plain:
            return textChunks(rendered.text).map { text in
                var chunk = rendered
                chunk.text = text
                return chunk
            }
        default: return [rendered]
        }
    }

    private func block(_ markup: any Markup, source: String, original: MarkdownSource) -> ChatMarkdownBlock {
        if let code = markup as? CodeBlock {
            let text = code.code
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let preview = prefix(lines.prefix(30).joined(separator: "\n"), bytes: 8_192)
            let snippet = ChatCodeSnippet(text: text, preview: preview, lineCount: lines.count,
                                          visibleLineCount: preview.split(separator: "\n", omittingEmptySubsequences: false).count,
                                          isTruncated: lines.count > 30 || text.utf8.count > preview.utf8.count)
            return ChatMarkdownBlock(kind: .code(code.language), source: source, text: AttributedString(text), code: snippet)
        }
        if markup is ThematicBreak {
            return ChatMarkdownBlock(kind: .separator, source: source, text: AttributedString())
        }
        if let table = markup as? Table {
            var rows = [Array(table.head.cells.prefix(8).map { self.tableCell($0) })]
            rows += table.body.rows.prefix(8).map { row in Array(row.cells.prefix(8).map { self.tableCell($0) }) }
            let omitted = table.body.childCount > 8 || table.head.childCount > 8 || rows.joined().contains { $0.isTruncated }
            return ChatMarkdownBlock(kind: .table, source: source, text: AttributedString(), table: rows.map { $0.map { $0.text } },
                                     hasOmittedContent: omitted)
        }
        if markup is UnorderedList || markup is OrderedList {
            return ChatMarkdownBlock(kind: .list, source: source, text: AttributedString(), list: listLines(markup, depth: 0, original: original))
        }
        if let heading = markup as? Heading {
            let content = heading.children.map { $0.format() }.joined()
            return ChatMarkdownBlock(kind: .heading(heading.level), source: source, text: inline(content))
        }
        if let quote = markup as? BlockQuote {
            let content = quote.children.map { inlineSource($0, original: original) }.joined(separator: "\n")
            return ChatMarkdownBlock(kind: .quote, source: source, text: inline(content))
        }
        if markup is HTMLBlock {
            return ChatMarkdownBlock(kind: .plain, source: source, text: AttributedString(source))
        }
        return ChatMarkdownBlock(kind: .paragraph, source: source, text: inline(source))
    }

    private func listLines(_ markup: any Markup, depth: Int, original: MarkdownSource) -> [ChatListLine] {
        let start = (markup as? OrderedList)?.startIndex
        var lines: [ChatListLine] = []
        for (index, child) in markup.children.enumerated() {
            guard let item = child as? ListItem else { continue }
            let marker: String
            if let checkbox = item.checkbox {
                marker = checkbox == .checked ? "☑" : "☐"
            } else if let start {
                marker = "\(start + UInt(index))."
            } else {
                marker = "•"
            }
            var isFirst = true
            for content in item.children {
                if content is UnorderedList || content is OrderedList {
                    lines += listLines(content, depth: depth + 1, original: original)
                } else {
                    let text = inline(inlineSource(content, original: original).trimmingCharacters(in: .newlines))
                    for chunk in textChunks(text) {
                        lines.append(ChatListLine(depth: depth, marker: isFirst ? marker : "", text: chunk))
                        isFirst = false
                    }
                }
            }
        }
        return lines
    }

    private func inlineSource(_ markup: any Markup, original: MarkdownSource) -> String {
        if containsTable(markup) { return original.text(in: markup.range) ?? original.whole }
        return markup.detachedFromParent.format()
    }

    private func containsTable(_ markup: any Markup) -> Bool {
        markup is Markdown.Table || markup.children.contains { containsTable($0) }
    }

    private func textChunks(_ text: AttributedString) -> [AttributedString] {
        var chunks: [AttributedString] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.characters.index(start, offsetBy: 2_048, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(AttributedString(text[start..<end]))
            start = end
        }
        return chunks.isEmpty ? [text] : chunks
    }

    private func tableCell(_ markup: any Markup) -> (text: AttributedString, isTruncated: Bool) {
        let source = markup.children.map { $0.format() }.joined()
        return (inline(prefix(source, bytes: 512)), source.utf8.count > 512)
    }

    private func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var text = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        for run in Array(text.runs) {
            if let link = run.link, !["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                text[run.range].link = nil
            }
        }
        return text
    }
}
