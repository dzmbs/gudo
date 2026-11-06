import Foundation
import HostKit
import Markdown

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

    enum Content: Equatable, Sendable {
        case markdown(ChatMarkdownBlock)
        case item(TimelineItem)
    }
}

nonisolated struct ChatMarkdownBlock: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph, heading(Int), quote, list, code(String?), table, separator, plain
    }

    let kind: Kind
    let source: String
    let text: AttributedString
    var list: [ChatListLine] = []
    var table: [[AttributedString]] = []
}

nonisolated struct ChatListLine: Equatable, Sendable {
    let depth: Int
    let marker: String
    let text: AttributedString
}

actor RowBuilder {
    private struct Entry {
        let revision: UInt32
        let rows: [ChatRow]
        let bytes: Int
    }

    private var cache: [String: Entry] = [:]
    private var recency: [String] = []
    private var cachedBytes = 0
    private var cachedRows = 0
    private(set) var parseCount = 0

    func rows(for item: TimelineItem) -> [ChatRow] {
        if let entry = cache[item.id], entry.revision == item.revision {
            touch(item.id)
            return entry.rows
        }
        let rows: [ChatRow]
        var bytes = ((try? TimelineJSON.encode(item).count) ?? 0) * 2 + 256
        if case .assistant(let assistant) = item.body {
            let blocks = markdown(assistant.text)
            rows = blocks.enumerated().map { index, block in
                ChatRow(id: ChatRowID(item: item.id, part: index), revision: item.revision, turn: item.turn, content: .markdown(block))
            }
            bytes = assistant.text.utf8.count * 4 + rows.count * 512 + 256
        } else {
            rows = [ChatRow(id: ChatRowID(item: item.id, part: 0), revision: item.revision, turn: item.turn, content: .item(item))]
        }
        if let previous = cache.removeValue(forKey: item.id) {
            cachedBytes -= previous.bytes
            cachedRows -= previous.rows.count
        }
        cache[item.id] = Entry(revision: item.revision, rows: rows, bytes: bytes)
        cachedBytes += bytes
        cachedRows += rows.count
        touch(item.id)
        while cache.count > 500 || cachedRows > 500 || cachedBytes > 4 * 1_024 * 1_024 {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cachedBytes -= removed.bytes
                cachedRows -= removed.rows.count
            }
        }
        return rows
    }

    func rows(for items: [TimelineItem]) -> [String: [ChatRow]] {
        var result: [String: [ChatRow]] = [:]
        for item in items { result[item.id] = rows(for: item) }
        return result
    }

    func remove(_ identifiers: Set<String>) {
        for identifier in identifiers {
            if let entry = cache.removeValue(forKey: identifier) {
                cachedBytes -= entry.bytes
                cachedRows -= entry.rows.count
            }
        }
        recency.removeAll { identifiers.contains($0) }
    }

    func clear() {
        cache.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
        cachedBytes = 0
        cachedRows = 0
    }

    var cacheSize: Int { cache.count }
    var cacheRowCount: Int { cachedRows }
    var cacheBytes: Int { cachedBytes }

    private func touch(_ identifier: String) {
        recency.removeAll { $0 == identifier }
        recency.append(identifier)
    }

    private func markdown(_ source: String) -> [ChatMarkdownBlock] {
        parseCount += 1
        let document = Document(parsing: source)
        return document.children.map { block($0) }
    }

    private func block(_ markup: any Markup) -> ChatMarkdownBlock {
        let source = markup.format().trimmingCharacters(in: .newlines)
        if let code = markup as? CodeBlock {
            return ChatMarkdownBlock(kind: .code(code.language), source: source, text: AttributedString(code.code))
        }
        if markup is ThematicBreak {
            return ChatMarkdownBlock(kind: .separator, source: source, text: AttributedString())
        }
        if let table = markup as? Table {
            var rows = [Array(table.head.cells.map { self.inlineChildren($0) })]
            rows += table.body.rows.map { row in Array(row.cells.map { self.inlineChildren($0) }) }
            return ChatMarkdownBlock(kind: .table, source: source, text: AttributedString(), table: rows)
        }
        if markup is UnorderedList || markup is OrderedList {
            return ChatMarkdownBlock(kind: .list, source: source, text: AttributedString(), list: listLines(markup, depth: 0))
        }
        if let heading = markup as? Heading {
            let content = heading.children.map { $0.format() }.joined()
            return ChatMarkdownBlock(kind: .heading(heading.level), source: source, text: inline(content))
        }
        if let quote = markup as? BlockQuote {
            let content = quote.children.map { $0.format() }.joined(separator: "\n")
            return ChatMarkdownBlock(kind: .quote, source: source, text: inline(content))
        }
        if markup is HTMLBlock {
            return ChatMarkdownBlock(kind: .plain, source: source, text: AttributedString(source))
        }
        return ChatMarkdownBlock(kind: .paragraph, source: source, text: inline(source))
    }

    private func listLines(_ markup: any Markup, depth: Int) -> [ChatListLine] {
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
                    lines += listLines(content, depth: depth + 1)
                } else {
                    lines.append(ChatListLine(depth: depth, marker: isFirst ? marker : "", text: inline(content.format().trimmingCharacters(in: .newlines))))
                    isFirst = false
                }
            }
        }
        return lines
    }

    private func inlineChildren(_ markup: any Markup) -> AttributedString {
        inline(markup.children.map { $0.format() }.joined())
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
