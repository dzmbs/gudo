#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI
import UIKit

struct ChatRowActions {
    var supportsDiffs = true
    var readsToolDetails = true
    var showTerminal: (UInt64?) -> Void = { _ in }
    var selectText: (String) -> Void = { _ in }
    var showTool: (TimelineItem) -> Void = { _ in }
    var showDiff: (ChatDiffTarget) -> Void = { _ in }
}

struct ChatRowView: View {
    let row: ChatRow
    let isExpanded: Bool
    let toggle: () -> Void
    let actions: ChatRowActions
    private static let maximumIndentationDepth = 12
    @ScaledMetric(relativeTo: .callout) private var tableLineHeight = DS.Size.proseTableLineHeight
    @ScaledMetric(relativeTo: .caption) private var outputLineHeight = DS.Size.proseOutputLineHeight
    @ScaledMetric(relativeTo: .body) private var diffLineHeight = DS.Size.proseDiffLineHeight
    @Environment(\.terminalTheme) private var terminalTheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.s)
            .foregroundStyle(DS.Palette.text)
            .buttonStyle(ChatRowButtonStyle())
            .contextMenu {
                Button(copyTitle, systemImage: "doc.on.doc") { UIPasteboard.general.string = plainText }
                Button(selectionTitle, systemImage: "text.cursor") { actions.selectText(plainText) }
                if case .item(let item) = row.content, case .tool(let tool) = item.body {
                    if !tool.input.isEmpty, let output = tool.output, !output.preview.isEmpty {
                        Button("Copy input") { UIPasteboard.general.string = tool.input }
                        Button("Copy output preview") { UIPasteboard.general.string = output.preview }
                    }
                }
                if case .markdown(let block) = row.content, !usesRawMarkdownSelection {
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
        case .omitted:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(verbatim: ChatRenderLimits.omittedMessage)
                    .font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
                Button("Open Terminal") { actions.showTerminal(nil) }
                    .font(DS.Font.caption).frame(minHeight: DS.Size.touchTarget)
            }
        }
    }

    @ViewBuilder private func markdown(_ block: ChatMarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text).font(DS.Font.prose).lineSpacing(DS.Space.badgeV)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(block.text)
                .font(level == 1 ? DS.Font.proseTitle : level == 2 ? DS.Font.title : DS.Font.proseHeading)
                .padding(.top, DS.Space.s)
                .fixedSize(horizontal: false, vertical: true)
        case .quote:
            HStack(alignment: .top, spacing: DS.Space.m) {
                RoundedRectangle(cornerRadius: DS.Radius.chip).fill(DS.Palette.border)
                    .frame(width: DS.Size.proseQuoteRule)
                Text(block.text).font(DS.Font.prose).foregroundStyle(DS.Palette.textSecondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .list:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(Array(block.list.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text(line.marker).foregroundStyle(DS.Palette.textSecondary)
                            .frame(minWidth: DS.Space.l, alignment: .trailing)
                        Text(line.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(min(line.depth, Self.maximumIndentationDepth)) * DS.Space.l)
                }
            }.font(DS.Font.prose).fixedSize(horizontal: false, vertical: true)
        case .code(let language):
            if let code = block.code {
                ChatCodeBlock(code: code, language: language) { actions.selectText(code.text) }
            }
        case .table:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: DS.Space.xl, verticalSpacing: DS.Space.gap10) {
                        ForEach(Array(block.table.enumerated()), id: \.offset) { index, cells in
                            GridRow {
                                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                    Text(cell).fontWeight(index == 0 ? .semibold : .regular)
                                        .fixedSize(horizontal: true, vertical: true)
                                        .frame(minWidth: DS.Size.proseTableColumn, alignment: .leading)
                                }
                            }
                            if index == 0 { Divider().gridCellColumns(cells.count) }
                        }
                    }.font(DS.Font.proseSecondary).padding(DS.Space.l)
                }
                .frame(height: CGFloat(block.table.count) * (tableLineHeight + DS.Space.gap10) + 2 * DS.Space.l)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.secureBadge))
                if block.hasOmittedContent {
                    Button("Open full table") { actions.selectText(block.source) }
                        .font(DS.Font.caption).frame(minHeight: DS.Size.touchTarget)
                }
            }
        case .separator:
            Rectangle().fill(DS.Palette.separator).frame(height: DS.Size.dividerVisible).padding(.vertical, DS.Space.s)
        case .plain:
            Text(block.text).font(DS.Font.literal).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func itemContent(_ item: TimelineItem) -> some View {
        switch item.body {
        case .user(let user): userContent(item, user: user)
        case .assistant(let assistant): Text(verbatim: assistant.text).font(DS.Font.prose)
        case .tool(let tool): toolContent(item, tool: tool)
        case .thinking(let thinking): thinkingContent(thinking)
        case .plan(let plan): planContent(plan)
        case .notice(let notice): noticeContent(notice)
        case .turnEnd(let end): turnEndContent(item, end: end)
        }
    }

    private func userContent(_ item: TimelineItem, user: TimelineUser) -> some View {
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            if user.queued {
                Label("Queued", systemImage: "clock").font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Text(verbatim: row.preview ?? user.text).font(DS.Font.prose)
                .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.panel))
            if row.preview != nil {
                Button("Read full prompt") { actions.selectText(user.text) }.font(DS.Font.caption)
            }
            ForEach(Array(user.attachments.prefix(12).enumerated()), id: \.offset) { _, attachment in
                Label((attachment.path as NSString).lastPathComponent, systemImage: "paperclip")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if user.attachments.count > 12 {
                Button("View all \(user.attachments.count) attachments") {
                    actions.selectText(user.attachments.map(\.path).joined(separator: "\n"))
                }.font(DS.Font.caption)
            }
            if item.origin == .terminal {
                Text("From Terminal").font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
            }
        }.frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, DS.Space.xxxl).padding(.vertical, DS.Space.row)
    }

    private func thinkingContent(_ thinking: TimelineThinking) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.gap10) {
            Button(action: toggle) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "sparkle")
                    Text(ChatItemPresentation.thinkingTitle(thinking))
                    Spacer(minLength: DS.Space.s)
                    if ChatItemPresentation.hasThinkingText(thinking) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(DS.Font.captionDetail)
                    }
                }.font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
                    .frame(minHeight: DS.Size.touchTarget)
            }.buttonStyle(ChatRowButtonStyle()).disabled(!ChatItemPresentation.hasThinkingText(thinking))
                .accessibilityValue(ChatItemPresentation.hasThinkingText(thinking) ? (isExpanded ? "Expanded" : "Collapsed") : "Text not recorded")
            if isExpanded, ChatItemPresentation.hasThinkingText(thinking), let text = thinking.text {
                Text(verbatim: row.preview ?? text).font(DS.Font.proseSecondary)
                    .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if row.preview != nil { Button("Read all") { actions.selectText(text) }.font(DS.Font.caption) }
            }
        }
    }

    private func planContent(_ plan: TimelinePlan) -> some View {
        let entries = row.planPreview?.entries ?? plan.entries
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            Label("Plan", systemImage: "checklist").font(DS.Font.proseSecondaryEmphasis)
            ForEach(Array(entries.prefix(20).enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.gap10) {
                    Image(systemName: entry.status == .known(.completed) ? "checkmark.circle.fill"
                        : entry.status == .known(.inProgress) ? "circle.dotted" : "circle")
                        .foregroundStyle(entry.status == .known(.completed) ? DS.Palette.done : DS.Palette.textSecondary)
                    Text(verbatim: entry.text).strikethrough(entry.status == .known(.completed))
                }.font(DS.Font.proseSecondary)
            }
            if row.planPreview != nil || plan.entries.count > 20 {
                Button("Read full plan") {
                    actions.selectText(plan.entries.map(\.text).joined(separator: "\n"))
                }.font(DS.Font.caption)
            }
        }.padding(DS.Space.l).background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.searchPanel))
    }

    private func noticeContent(_ notice: TimelineNotice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text(verbatim: row.preview ?? notice.text).foregroundStyle(DS.Palette.textSecondary)
            } icon: {
                Image(systemName: notice.kind == .known(.error) ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(notice.kind == .known(.error) ? DS.Palette.error : DS.Palette.info)
            }.font(DS.Font.proseSecondary)
            if row.preview != nil { Button("Read all") { actions.selectText(notice.text) }.font(DS.Font.caption) }
        }
    }

    private func turnEndContent(_ item: TimelineItem, end: TimelineTurnEnd) -> some View {
        HStack(spacing: DS.Space.s) {
            Text("Worked for \(duration(end.durationMs))")
            if let tokens = end.outputTokens { Text("· \(tokens.formatted(.number.notation(.compactName))) tokens") }
            Spacer(minLength: 0)
            if actions.supportsDiffs {
                Button("Changes", systemImage: "plus.forwardslash.minus") { actions.showDiff(.turn(item.turn)) }
            }
        }.font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary).padding(.vertical, DS.Space.s)
    }

    private func toolContent(_ item: TimelineItem, tool: TimelineTool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.gap10) {
            Button(action: toggle) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: toolGlyph(tool.kind))
                        .frame(width: DS.Space.l)
                        .foregroundStyle(tool.status == .known(.failed) ? DS.Palette.error : DS.Palette.textSecondary)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(verbatim: ChatItemPresentation.toolTitle(tool)).font(DS.Font.proseSecondary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .shimmering(tool.status == .known(.running), text: ChatItemPresentation.toolTitle(tool))
                        Text(ChatItemPresentation.toolKind(tool) + " · " + ChatItemPresentation.toolStatus(tool))
                            .font(DS.Font.captionDetail)
                            .foregroundStyle(tool.status == .known(.failed) || tool.status == .known(.denied)
                                             ? DS.Palette.error : DS.Palette.textSecondary)
                    }
                    Spacer(minLength: DS.Space.xs)
                    if !tool.diff.isEmpty {
                        Text("+\(tool.diff.reduce(UInt64(0)) { $0 + UInt64($1.additions) })")
                            .foregroundStyle(DS.Palette.done)
                        Text("−\(tool.diff.reduce(UInt64(0)) { $0 + UInt64($1.deletions) })")
                            .foregroundStyle(DS.Palette.error)
                    } else if let time = tool.durationMs { Text(duration(time)).foregroundStyle(DS.Palette.textTertiary) }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
                }.font(DS.Font.meta).frame(minHeight: DS.Size.touchTarget)
            }.buttonStyle(ChatRowButtonStyle())
                .accessibilityLabel(ChatItemPresentation.toolKind(tool) + ": " + ChatItemPresentation.toolTitle(tool))
                .accessibilityValue([ChatItemPresentation.toolStatus(tool), tool.durationMs.map(duration),
                                     isExpanded ? "Expanded" : "Collapsed"].compactMap { $0 }.joined(separator: ", "))
            if isExpanded {
                if !tool.input.isEmpty {
                    Text(verbatim: String(tool.input.prefix(2_000))).font(DS.Font.literalSmall)
                        .foregroundStyle(DS.Palette.textSecondary).lineLimit(8)
                }
                if let output = tool.output, !output.preview.isEmpty {
                    ScrollView(.horizontal) {
                        Text(verbatim: output.preview.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n"))
                            .font(DS.Font.literalSmall).foregroundStyle(terminalTheme.foreground)
                            .fixedSize(horizontal: true, vertical: true).padding(DS.Space.m)
                    }
                    .frame(height: CGFloat(min(output.preview.split(separator: "\n", omittingEmptySubsequences: false).count, 12)) * outputLineHeight + 2 * DS.Space.m)
                    .background(DS.Palette.terminal, in: .rect(cornerRadius: DS.Radius.pane))
                }
                if let preview = row.inlineDiff { inlineDiff(preview) }
                if tool.kind == .known(.task) {
                    Text("Nested subagent transcripts are not available in this Chat. Use Terminal.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                HStack {
                    if actions.readsToolDetails {
                        Button("Details", systemImage: "arrow.up.left.and.arrow.down.right") { actions.showTool(item) }
                    }
                    if actions.readsToolDetails, actions.supportsDiffs, !tool.diff.isEmpty {
                        Button("Changes", systemImage: "plus.forwardslash.minus") {
                            actions.showDiff(.tool(item: item.id, path: nil))
                        }.accessibilityIdentifier("chat-tool-changes-\(item.id)")
                    }
                    Spacer()
                    Button("Show in Terminal", systemImage: "terminal") { actions.showTerminal(tool.commandMark) }
                }.font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func inlineDiff(_ preview: ChatInlineDiff) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Recorded diff preview").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    ForEach(preview.file.hunks.first?.lines ?? []) { line in
                        DiffLineContent(file: preview.file, left: line, right: nil, split: false, lineHeight: diffLineHeight)
                    }
                }
            }
            .frame(height: CGFloat(preview.file.hunks.first?.lines.count ?? 0) * diffLineHeight)
            .clipShape(.rect(cornerRadius: DS.Radius.secureBadge))
        }
    }

    private func toolSelectionText(_ tool: TimelineTool) -> String {
        let text = [tool.input, tool.output?.preview ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        return text.isEmpty ? ChatItemPresentation.toolTitle(tool) + "\n" + ChatItemPresentation.toolStatus(tool) : text
    }

    private var usesRawMarkdownSelection: Bool {
        if case .markdown(let block) = row.content { return block.hasOmittedContent }
        return false
    }

    private var toolSelectionContent: String? {
        guard case .item(let item) = row.content, case .tool(let tool) = item.body else { return nil }
        let input = !tool.input.isEmpty, output = tool.output?.preview.isEmpty == false
        return input && output ? "input and output preview" : input ? "input" : output ? "output preview" : "tool summary"
    }

    var copyTitle: String {
        toolSelectionContent.map { "Copy " + $0 } ?? (usesRawMarkdownSelection ? "Copy raw Markdown" : "Copy")
    }
    var selectionTitle: String {
        toolSelectionContent.map { "Select " + $0 } ?? (usesRawMarkdownSelection ? "Select raw Markdown" : "Select Text")
    }

    var plainText: String {
        switch row.content {
        case .markdown(let block): markdownSelectionText(block)
        case .omitted: ChatRenderLimits.omittedMessage
        case .item(let item):
            switch item.body {
            case .user(let value): value.text
            case .assistant(let value): value.text
            case .thinking(let value): ChatItemPresentation.hasThinkingText(value) ? value.text ?? "" : ChatItemPresentation.thinkingTitle(value)
            case .tool(let value): toolSelectionText(value)
            case .plan(let value): value.entries.map(\.text).joined(separator: "\n")
            case .notice(let value): value.text
            case .turnEnd(let value): "Worked for \(duration(value.durationMs))"
            }
        }
    }

    private func markdownSelectionText(_ block: ChatMarkdownBlock) -> String {
        // Do not label an omitted table/list preview as complete plain text. Its menu explicitly
        // offers the original raw Markdown instead; Copy as Markdown never uses a padded formatter.
        if block.hasOmittedContent { return block.source }
        switch block.kind {
        case .list:
            return block.list.map { line in
                let depth = max(0, min(line.depth, Self.maximumIndentationDepth))
                return String(repeating: "  ", count: depth) + line.marker + " " + String(line.text.characters)
            }.joined(separator: "\n")
        case .table:
            return block.table.map { cells in
                cells.map { String($0.characters) }.joined(separator: "\t")
            }.joined(separator: "\n")
        case .separator: return block.source
        default: return String(block.text.characters)
        }
    }

    private func duration(_ milliseconds: UInt64) -> String { ChatItemPresentation.duration(milliseconds) }

    private func toolGlyph(_ kind: TimelineToolKind) -> String {
        switch kind {
        case .known(.shell): "terminal"
        case .known(.read): "doc.text"
        case .known(.search): "magnifyingglass"
        case .known(.edit), .known(.write): "pencil.line"
        case .known(.fetch), .known(.webSearch): "globe"
        case .known(.mcp): "puzzlepiece.extension"
        case .known(.task): "square.stack.3d.up"
        case .known(.other), .unknown: "wrench.and.screwdriver"
        }
    }
}

private struct ChatRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minHeight: DS.Size.touchTarget).contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(DS.Palette.selection.opacity(configuration.isPressed ? 1 : 0)))
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
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1

    private var lineHeight: CGFloat {
        let font = TerminalFont.regular.flatMap { UIFont(name: $0, size: fontSize) }
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ceil((font.lineHeight + DS.Space.xxs) * scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language ?? "Code" : "Code")
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = code.text }
            }.font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.m).frame(height: DS.Size.touchTarget)
                .background(DS.Palette.raised)
            ScrollView(.horizontal) {
                Text(ChatCodeStyler.text(code, theme: terminalTheme, increasedContrast: contrast == .increased))
                    .font(TerminalFont.font(size: fontSize, relativeTo: .callout)).lineSpacing(DS.Space.xxs * scale)
                    .fixedSize(horizontal: true, vertical: true).padding(DS.Space.m)
            }
            .frame(height: CGFloat(code.visibleLineCount) * lineHeight + 2 * DS.Space.m)
            if code.isTruncated {
                Button(code.lineCount == 1 ? "Show full code" : "Show all \(code.lineCount) lines", action: showAll)
                    .font(DS.Font.caption).padding(.horizontal, DS.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DS.Palette.textSecondary).background(DS.Palette.raised)
            }
        }
        .background(DS.Palette.terminal, in: .rect(cornerRadius: DS.Radius.secureBadge))
        .clipShape(.rect(cornerRadius: DS.Radius.secureBadge))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.secureBadge).strokeBorder(DS.Palette.hairline) }
    }
}
#endif
