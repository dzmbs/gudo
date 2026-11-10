// Incremental partitioning adapted from OpenAI Codex, Copyright 2025 OpenAI, Apache-2.0.
// Modified for native block rows and Swift Markdown source ranges.
import ChatSyntax
import Foundation
import HostKit
import Markdown

nonisolated enum ChatRenderLimits {
    static let rowsPerMessage = 3_000
    static let rowsPerPage = 3_000
    static let bytesPerPage = 8 * 1_024 * 1_024
    static let pageNotice = "This Chat page exceeds the rendering budget. Open Terminal."
    static let markdownBytes = 256 * 1_024
    static let omittedMessage = "This message is too large for Chat. Open Terminal to read it."
}

nonisolated enum ChatCacheLimits {
    static let entries = 500
    static let paragraphProfiles = 8
    static let bytes = 4 * 1_024 * 1_024
}

nonisolated struct RenderedChatRows: Sendable {
    let rows: [ChatRow]
    let cost: LRUCost
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
    var inlineDiff: ChatInlineDiff?

    var awaitsHighlights: Bool {
        if case .markdown(let block) = content { block.awaitsHighlights } else { false }
    }

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

    var awaitsHighlights: Bool { code?.awaitsHighlights == true }
}

nonisolated struct ChatCodeSnippet: Equatable, Sendable {
    let text: String
    let preview: String
    let lineCount: Int
    let visibleLineCount: Int
    let isTruncated: Bool
    var highlights: [CodeToken] = []
    var awaitsHighlights = false
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

nonisolated final class RowBuilder {
    private struct MarkdownPartition {
        let source: String
        let blocks: [ChatMarkdownBlock]
        let stableBytes: Int
        let stableBlocks: Int
    }

    private struct Entry {
        let revision: UInt32
        let rows: [ChatRow]
        let cost: LRUCost
        let partition: MarkdownPartition?
        let awaitsHighlights: Bool
    }

    private let cache = BoundedLRU<String, Entry>(
        capacity: ChatCacheLimits.entries, byteLimit: ChatCacheLimits.bytes, unitLimit: ChatCacheLimits.entries
    )
    private let codeHighlighter = ChatSyntax.CodeHighlighter()
    private let inlineCache = BoundedLRU<String, AttributedString>(capacity: 32, byteLimit: 64 * 1_024, unitLimit: 32)
    private(set) var parseCount = 0
    private(set) var parsedBytes = 0
    private(set) var lastRenderDuration = Duration.zero
    private(set) var itemsAwaitingHighlights: Set<String> = []
    static let highlightAllowance = Duration.milliseconds(4)

    func beginPage() { codeHighlighter.beginAllowance(Self.highlightAllowance) }
    func endPage() { codeHighlighter.endAllowance() }

    func rows(for item: TimelineItem) -> [ChatRow] { render(item).rows }

    func render(_ item: TimelineItem) -> RenderedChatRows {
        let start = ContinuousClock.now
        defer { lastRenderDuration = start.duration(to: .now) }
        let previous = cache.value(for: item.id)
        if let previous, previous.revision == item.revision, !previous.awaitsHighlights {
            return RenderedChatRows(rows: previous.rows, cost: previous.cost)
        }
        let rows: [ChatRow]
        var bytes = TimelineValueWeight.of(item)
        var partition: MarkdownPartition?
        if case .assistant(let assistant) = item.body {
            guard let rendered = markdown(assistant.text, after: previous?.partition, streaming: assistant.streaming) else {
                cache.remove(item.id)
                itemsAwaitingHighlights.remove(item.id)
                let row = ChatRow(id: ChatRowID(item: item.id, part: 0), revision: item.revision,
                                  turn: item.turn, content: .omitted)
                let bytes = 2 * (item.id.utf8.count + (item.turn?.utf8.count ?? 0)) + rowOverhead + 256
                return RenderedChatRows(rows: [row], cost: LRUCost(bytes: bytes, units: 1))
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
            bytes += assistant.text.utf8.count * 2
            bytes += blocks.reduce(0) { $0 + ($1.code?.highlights.count ?? 0) * 32 }
        } else {
            let row = plainRow(item)
            rows = [row]
            bytes += row.inlineDiff?.bytes ?? 0
        }
        bytes += rows.count * rowOverhead + 256
        let cost = LRUCost(bytes: bytes, units: rows.count)
        let awaitsHighlights = rows.contains(where: \.awaitsHighlights)
        if awaitsHighlights { itemsAwaitingHighlights.insert(item.id) } else { itemsAwaitingHighlights.remove(item.id) }
        cache.insert(Entry(revision: item.revision, rows: rows, cost: cost, partition: partition, awaitsHighlights: awaitsHighlights),
                     for: item.id, cost: cost)
        return RenderedChatRows(rows: rows, cost: cost)
    }

    func remove(_ identifiers: Set<String>) {
        for identifier in identifiers { cache.remove(identifier) }
        itemsAwaitingHighlights.subtract(identifiers)
    }

    func clear() {
        cache.removeAll()
        itemsAwaitingHighlights.removeAll()
    }

    var cacheSize: Int { cache.count }
    var cacheRowCount: Int { cache.cost.units }
    var cacheBytes: Int { cache.cost.bytes }

    private var rowOverhead: Int { max(512, 2 * MemoryLayout<ChatRow>.stride) }

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
        let diff: ChatInlineDiff?
        if case .tool(let tool) = item.body { diff = ChatInlineDiff(tool: tool, item: item.id) } else { diff = nil }
        return ChatRow(id: ChatRowID(item: item.id, part: 0), revision: item.revision, turn: item.turn,
                       content: .item(item), preview: preview, planPreview: planPreview, inlineDiff: diff)
    }

    private func prefix(_ text: String, bytes: Int) -> String {
        var prefix = Array(text.utf8.prefix(bytes))
        while String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return String(decoding: prefix, as: UTF8.self)
    }

    private func markdown(_ source: String, after previous: MarkdownPartition?, streaming: Bool) -> MarkdownPartition? {
        guard source.utf8.count <= ChatRenderLimits.markdownBytes else { return nil }
        if let previous, previous.source == source, !previous.blocks.contains(where: \.awaitsHighlights) { return previous }
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
        inlineCache.removeAll()
        defer { inlineCache.removeAll() }
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
        var hasStableEnd = false
        for (index, markup) in document.children.enumerated() {
            let rows = blockRows(markup, original: original, cachesHighlights: !streaming || index < boundary)
            if !hasStableEnd, index == boundary || rows.contains(where: \.awaitsHighlights) {
                hasStableEnd = true
                if let start = original.blockStart(markup.range) {
                    stableBytes = offset + start
                    stableBlocks = blocks.count
                }
            }
            guard rows.count <= ChatRenderLimits.rowsPerMessage - blocks.count else { return nil }
            blocks.append(contentsOf: rows)
        }
        return MarkdownPartition(source: source, blocks: blocks, stableBytes: stableBytes, stableBlocks: stableBlocks)
    }

    private func blockRows(_ markup: any Markup, original: MarkdownSource, cachesHighlights: Bool) -> [ChatMarkdownBlock] {
        let rendered = block(markup, source: original.text(in: markup.range) ?? original.whole, original: original,
                             cachesHighlights: cachesHighlights)
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

    private func block(_ markup: any Markup, source: String, original: MarkdownSource, cachesHighlights: Bool) -> ChatMarkdownBlock {
        if let code = markup as? CodeBlock {
            let text = code.code
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let preview = prefix(lines.prefix(30).joined(separator: "\n"), bytes: 8_192)
            let highlighting = codeHighlighter.highlighting(preview, language: CodeLanguage(fence: code.language),
                                                            caches: cachesHighlights)
            var highlights: [CodeToken] = []
            if case .tokens(let tokens) = highlighting { highlights = tokens }
            let snippet = ChatCodeSnippet(text: text, preview: preview, lineCount: lines.count,
                                          visibleLineCount: preview.split(separator: "\n", omittingEmptySubsequences: false).count,
                                          isTruncated: lines.count > 30 || text.utf8.count > preview.utf8.count,
                                          highlights: highlights, awaitsHighlights: highlighting == .deferred)
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
        return ChatMarkdownBlock(kind: .paragraph, source: source, text: inline(source, markup: markup))
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
            // Most blocks already fit. Preserve their attributed storage instead of rebuilding
            // an identical whole-value slice for every paragraph in a cold document.
            if start == text.startIndex, end == text.endIndex { return [text] }
            chunks.append(AttributedString(text[start..<end]))
            start = end
        }
        return chunks.isEmpty ? [text] : chunks
    }

    private func tableCell(_ markup: any Markup) -> (text: AttributedString, isTruncated: Bool) {
        let source = markup.children.map { $0.format() }.joined()
        return (inline(prefix(source, bytes: 512)), source.utf8.count > 512)
    }

    private func inline(_ markdown: String, markup: (any Markup)? = nil) -> AttributedString {
        if let cached = inlineCache.value(for: markdown) { return cached }
        var text: AttributedString
        if let prepared = ChatInlineValues.flat(markup, source: markdown) { text = prepared }
        else {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
            text = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
            var unsafeLinks: [Range<AttributedString.Index>] = []
            for run in text.runs {
                guard let link = run.link else { continue }
                switch link.scheme?.lowercased() {
                case "https", "http", "mailto": break
                default: unsafeLinks.append(run.range)
                }
            }
            for range in unsafeLinks { text[range].link = nil }
        }
        inlineCache.insert(text, for: markdown, cost: LRUCost(bytes: markdown.utf8.count * 4 + 512, units: 1))
        return text
    }
}
