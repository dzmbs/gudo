#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI
import UIKit

struct ChatRowActions {
    var showTerminal: (UInt64?) -> Void = { _ in }
    var selectText: (String) -> Void = { _ in }
    var showTool: (TimelineItem) -> Void = { _ in }
    var showDiff: (String?) -> Void = { _ in }
}

struct ChatRowView: View {
    let row: ChatRow
    let isExpanded: Bool
    let toggle: () -> Void
    let actions: ChatRowActions
    @ScaledMetric(relativeTo: .callout) private var tableLineHeight = 24
    @ScaledMetric(relativeTo: .caption) private var outputLineHeight = 16
    @Environment(\.terminalTheme) private var terminalTheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            .foregroundStyle(DS.Palette.text)
            .buttonStyle(ChatRowButtonStyle())
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = plainText }
                Button("Select Text", systemImage: "text.cursor") { actions.selectText(plainText) }
                if case .markdown(let block) = row.content {
                    Button("Copy as Markdown") { UIPasteboard.general.string = block.source }
                }
                Button("Show in Terminal", systemImage: "terminal") {
                    if case .item(let item) = row.content, case .tool(let tool) = item.body {
                        actions.showTerminal(tool.commandMark)
                    } else { actions.showTerminal(nil) }
                }
            }
            .accessibilityIdentifier("chat-row-\(row.id.storageKey)")
    }

    @ViewBuilder private var content: some View {
        switch row.content {
        case .markdown(let block): markdown(block)
        case .item(let item): itemContent(item)
        }
    }

    @ViewBuilder private func markdown(_ block: ChatMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text).font(.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(block.text)
                .font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(DS.Palette.border).frame(width: 3)
                Text(block.text).font(.body).foregroundStyle(DS.Palette.textSecondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .list:
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(block.list.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(line.marker).foregroundStyle(DS.Palette.textSecondary).frame(minWidth: 16, alignment: .trailing)
                        Text(line.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(min(line.depth, 12)) * 16)
                }
            }.font(.body).fixedSize(horizontal: false, vertical: true)
        case .code(let language):
            if let code = block.code {
                ChatCodeBlock(code: code, language: language) { actions.selectText(code.text) }
            }
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    ForEach(Array(block.table.enumerated()), id: \.offset) { index, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                Text(cell).fontWeight(index == 0 ? .semibold : .regular)
                                    .fixedSize(horizontal: true, vertical: true)
                                    .frame(minWidth: 80, alignment: .leading)
                            }
                        }
                        if index == 0 { Divider().gridCellColumns(cells.count) }
                    }
                }.font(.callout).padding(14)
            }
            .frame(height: CGFloat(block.table.count) * (tableLineHeight + 10) + 30)
            .background(DS.Palette.raised, in: .rect(cornerRadius: 12))
            if block.hasOmittedContent {
                Button("Open full table") { actions.selectText(block.source) }.font(.caption)
            }
        case .separator:
            Rectangle().fill(DS.Palette.separator).frame(height: 1).padding(.vertical, 8)
        case .plain:
            Text(block.text).font(DS.Font.literal).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func itemContent(_ item: TimelineItem) -> some View {
        switch item.body {
        case .user(let user):
            VStack(alignment: .trailing, spacing: 7) {
                if user.queued { Label("Queued", systemImage: "clock").font(.caption).foregroundStyle(DS.Palette.textSecondary) }
                Text(verbatim: row.preview ?? user.text).font(.body).padding(.horizontal, 15).padding(.vertical, 11)
                    .background(DS.Palette.raised, in: .rect(cornerRadius: 18))
                if row.preview != nil {
                    Button("Read full prompt") { actions.selectText(user.text) }.font(.caption)
                }
                ForEach(Array(user.attachments.prefix(12).enumerated()), id: \.offset) { _, attachment in
                    Label((attachment.path as NSString).lastPathComponent, systemImage: "paperclip")
                        .font(.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                if user.attachments.count > 12 {
                    Button("View all \(user.attachments.count) attachments") {
                        actions.selectText(user.attachments.map(\.path).joined(separator: "\n"))
                    }.font(.caption)
                }
                if item.origin == .terminal { Text("From Terminal").font(.caption2).foregroundStyle(DS.Palette.textTertiary) }
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 28).padding(.vertical, 5)
        case .assistant(let assistant): Text(verbatim: assistant.text).font(.body)
        case .tool(let tool): toolContent(item, tool: tool)
        case .thinking(let thinking):
            VStack(alignment: .leading, spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                        Text(thinking.durationMs.map { "Thought for \(duration($0))" } ?? "Thinking")
                        Spacer(minLength: 8)
                        if thinking.text != nil { Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption2) }
                    }.font(.callout).foregroundStyle(DS.Palette.textSecondary).frame(minHeight: 30)
                }.buttonStyle(ChatRowButtonStyle()).disabled(thinking.text == nil)
                if isExpanded, let text = thinking.text {
                    Text(verbatim: row.preview ?? text).font(.callout).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.preview != nil { Button("Read all") { actions.selectText(text) }.font(.caption) }
                }
            }
        case .plan(let plan):
            let entries = row.planPreview?.entries ?? plan.entries
            VStack(alignment: .leading, spacing: 11) {
                Label("Plan", systemImage: "checklist").font(.callout.weight(.semibold))
                ForEach(Array(entries.prefix(20).enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: entry.status == "Completed" ? "checkmark.circle.fill" : entry.status == "InProgress" ? "circle.dotted" : "circle")
                            .foregroundStyle(entry.status == "Completed" ? DS.Palette.done : DS.Palette.textSecondary)
                        Text(verbatim: entry.text).strikethrough(entry.status == "Completed")
                    }.font(.callout)
                }
                if row.planPreview != nil || plan.entries.count > 20 {
                    Button("Read full plan") { actions.selectText(plan.entries.map(\.text).joined(separator: "\n")) }.font(.caption)
                }
            }.padding(15).background(DS.Palette.raised, in: .rect(cornerRadius: 14))
        case .notice(let notice):
            VStack(alignment: .leading, spacing: 0) {
                Label {
                    Text(verbatim: row.preview ?? notice.text).foregroundStyle(DS.Palette.textSecondary)
                } icon: {
                    Image(systemName: notice.kind == "Error" ? "exclamationmark.circle" : "info.circle")
                        .foregroundStyle(notice.kind == "Error" ? DS.Palette.error : DS.Palette.info)
                }.font(.callout)
                if row.preview != nil { Button("Read all") { actions.selectText(notice.text) }.font(.caption) }
            }
        case .turnEnd(let end):
            HStack(spacing: 9) {
                Text("Worked for \(duration(end.durationMs))")
                if let tokens = end.outputTokens { Text("· \(tokens.formatted(.number.notation(.compactName))) tokens") }
                Spacer(minLength: 0)
                Button("Changes", systemImage: "plus.forwardslash.minus") { actions.showDiff(item.turn) }
            }.font(.caption).foregroundStyle(DS.Palette.textSecondary).padding(.vertical, 7)
        }
    }

    private func toolContent(_ item: TimelineItem, tool: TimelineTool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 9) {
                    Image(systemName: toolGlyph(tool.kind))
                        .frame(width: 16).foregroundStyle(tool.status == "Failed" ? DS.Palette.error : DS.Palette.textSecondary)
                    Text(verbatim: tool.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                        .shimmering(tool.status == "Running", text: tool.title)
                    Spacer(minLength: 4)
                    if !tool.diff.isEmpty {
                        Text("+\(tool.diff.reduce(UInt64(0)) { $0 + UInt64($1.additions) })")
                            .foregroundStyle(DS.Palette.done)
                        Text("−\(tool.diff.reduce(UInt64(0)) { $0 + UInt64($1.deletions) })")
                            .foregroundStyle(DS.Palette.error)
                    } else if let time = tool.durationMs { Text(duration(time)).foregroundStyle(DS.Palette.textTertiary) }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(DS.Palette.textTertiary)
                }.font(.caption.monospacedDigit()).frame(minHeight: 30)
            }.buttonStyle(ChatRowButtonStyle())
            if isExpanded {
                if !tool.input.isEmpty {
                    Text(verbatim: String(tool.input.prefix(2_000))).font(DS.Font.literalSmall)
                        .foregroundStyle(DS.Palette.textSecondary).lineLimit(8)
                }
                if let output = tool.output, !output.preview.isEmpty {
                    ScrollView(.horizontal) {
                        Text(verbatim: output.preview.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n"))
                            .font(DS.Font.literalSmall).foregroundStyle(terminalTheme.foreground)
                            .fixedSize(horizontal: true, vertical: true).padding(12)
                    }
                    .frame(height: CGFloat(min(output.preview.split(separator: "\n", omittingEmptySubsequences: false).count, 12)) * outputLineHeight + 24)
                    .background(DS.Palette.terminal, in: .rect(cornerRadius: 10))
                }
                HStack {
                    Button("Details", systemImage: "arrow.up.left.and.arrow.down.right") { actions.showTool(item) }
                    Spacer()
                    Button("Show in Terminal", systemImage: "terminal") { actions.showTerminal(tool.commandMark) }
                }.font(.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var plainText: String {
        switch row.content {
        case .markdown(let block): block.source
        case .item(let item):
            switch item.body {
            case .user(let value): value.text
            case .assistant(let value): value.text
            case .thinking(let value): value.text ?? "Thinking"
            case .tool(let value): [value.input, value.output?.preview ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            case .plan(let value): value.entries.map(\.text).joined(separator: "\n")
            case .notice(let value): value.text
            case .turnEnd(let value): "Worked for \(duration(value.durationMs))"
            }
        }
    }

    private func duration(_ milliseconds: UInt64) -> String {
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        let seconds = milliseconds / 1_000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    private func toolGlyph(_ kind: String) -> String {
        switch kind {
        case "Shell": "terminal"
        case "Read": "doc.text"
        case "Search": "magnifyingglass"
        case "Edit", "Write": "pencil.line"
        case "Fetch", "WebSearch": "globe"
        case "Mcp": "puzzlepiece.extension"
        case "Task": "square.stack.3d.up"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct ChatRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minHeight: 44).contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.selection.opacity(configuration.isPressed ? 1 : 0)))
            .animation(reduceMotion ? nil : DS.Motion.press, value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

private struct ChatCodeBlock: View {
    let code: ChatCodeSnippet
    let language: String?
    let showAll: () -> Void
    @Environment(\.terminalTheme) private var terminalTheme
    @AppStorage(TerminalPreferences.Key.fontSize) private var fontSize = TerminalPreferences.Default.fontSize
    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1

    private var lineHeight: CGFloat {
        let font = TerminalFont.regular.flatMap { UIFont(name: $0, size: fontSize) } ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ceil((font.lineHeight + 2) * scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language ?? "Code" : "Code")
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = code.text }
            }.font(.caption).foregroundStyle(DS.Palette.textSecondary).padding(.horizontal, 13).frame(height: 44)
                .background(DS.Palette.raised)
            ScrollView(.horizontal) {
                Text(verbatim: code.preview)
                    .font(TerminalFont.font(size: fontSize, relativeTo: .callout)).lineSpacing(2 * scale)
                    .foregroundStyle(terminalTheme.foreground)
                    .fixedSize(horizontal: true, vertical: true).padding(13)
            }
            .frame(height: CGFloat(code.visibleLineCount) * lineHeight + 26)
            if code.isTruncated {
                Button(code.lineCount == 1 ? "Show full code" : "Show all \(code.lineCount) lines", action: showAll)
                    .font(.caption).padding(.horizontal, 13).frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DS.Palette.textSecondary).background(DS.Palette.raised)
            }
        }
        .background(DS.Palette.terminal, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Palette.hairline) }
    }
}
#endif
