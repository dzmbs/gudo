import DesignSystem
import Foundation
import SwiftUI

/// A Markdown document as blocks: headings, paragraphs, list items, quotes, code and rules.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case code
        case listItem(marker: String)
        case rule
    }

    var id: Int
    var kind: Kind
    var text: AttributedString
    var depth: Int
    var isQuote: Bool

    static func parse(_ source: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source), depth: 0, isQuote: false)]
        }
        var blocks: [MarkdownBlock] = []
        for run in document.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? -1
            let text = AttributedString(document[run.range])
            if let last = blocks.last, last.id == identity {
                blocks[blocks.count - 1].text += text
            } else {
                blocks.append(MarkdownBlock(
                    id: identity, kind: kind(of: components), text: text,
                    depth: components.filter(\.isList).count, isQuote: components.contains { $0.kind == .blockQuote }))
            }
        }
        return blocks.map { block in
            var block = block
            if block.kind == .code, block.text.characters.last == "\n" {
                block.text.characters.removeLast()
            }
            return block
        }
    }

    private static func kind(of components: [PresentationIntent.IntentType]) -> Kind {
        for component in components {
            switch component.kind {
            case .header(let level): return .heading(level: level)
            case .codeBlock: return .code
            case .thematicBreak: return .rule
            case .listItem(let ordinal):
                let ordered = components.contains { $0.kind == .orderedList }
                return .listItem(marker: ordered ? "\(ordinal)." : "•")
            default: continue
            }
        }
        return .paragraph
    }
}

private extension PresentationIntent.IntentType {
    var isList: Bool { kind == .orderedList || kind == .unorderedList }
}

struct MarkdownDocumentView: View {
    let source: String
    @Environment(\.terminalTheme) private var theme
    @Environment(\.chrome) private var chrome

    var body: some View {
        let blocks = MarkdownBlock.parse(source)
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(blocks) { block in
                    blockView(block)
                        .padding(.leading, CGFloat(max(0, block.depth - 1)) * DS.Space.l)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .foregroundStyle(theme.foreground)
        .background(theme.background)
        .accessibilityIdentifier("file-viewer-rendered")
    }

    @ViewBuilder private func blockView(_ block: MarkdownBlock) -> some View {
        let content = Group {
            switch block.kind {
            case .paragraph:
                Text(block.text).font(DS.Font.rowTitle)
            case .heading(let level):
                Text(block.text)
                    .font(level == 1 ? .title2.weight(.bold) : level == 2 ? DS.Font.title : .headline)
                    .padding(.top, level <= 2 ? DS.Space.s : 0)
            case .code:
                Text(block.text)
                    .font(DS.Font.literal)
                    .padding(DS.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(chrome.raised.color, in: .rect(cornerRadius: DS.Radius.control))
            case .listItem(let marker):
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(verbatim: marker)
                        .font(DS.Font.rowTitle.monospacedDigit())
                        .foregroundStyle(DS.Palette.textSecondary)
                    Text(block.text).font(DS.Font.rowTitle)
                }
            case .rule:
                theme.splitDivider.frame(height: 1)
            }
        }
        if block.isQuote {
            content
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.leading, DS.Space.m)
                .overlay(alignment: .leading) { theme.splitDivider.frame(width: 3) }
        } else {
            content
        }
    }
}
