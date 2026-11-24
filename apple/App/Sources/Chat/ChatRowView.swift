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
    var showLongText: (TimelineLongText) -> Void = { _ in }
    var showDiff: (ChatDiffTarget) -> Void = { _ in }
    /// Sends a prompt again; nil where this agent cannot be sent to from Chat.
    var resend: ((String) -> Void)?
    /// Reads an image file on the host; nil where this viewer may not read files.
    var loadImage: ChatImageLoader?
    /// The agent's folder: paths inside it read relative to it.
    var workingDirectory: String?
}

struct ChatRowView: View {
    let row: ChatRow
    let isExpanded: Bool
    let toggle: () -> Void
    let actions: ChatRowActions
    var topSpacing: CGFloat = 0
    private static let maximumIndentationDepth = 12
    @ScaledMetric(relativeTo: .callout) private var tableColumnMinimum = DS.Size.proseTableColumn
    @ScaledMetric(relativeTo: .callout) private var tableColumnMaximum = DS.Size.proseTableColumnMaximum
    @ScaledMetric(relativeTo: .caption) private var outputLineHeight = DS.Size.proseOutputLineHeight
    @ScaledMetric(relativeTo: .body) private var diffLineHeight = DS.Size.proseDiffLineHeight
    @Environment(\.terminalTheme) private var terminalTheme
    @Environment(\.chatRowWidth) private var rowWidth
    @Environment(\.chrome) private var chrome

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, topSpacing)
            .frame(maxWidth: ChatReadingColumn.maximumWidth)
            .frame(maxWidth: .infinity)
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
        case .showAll(let longText): showAllContent(longText)
        case .toolGroup(let group): toolGroupContent(group)
        case .turnSummary(let summary): turnSummaryContent(summary)
        case .turnFooter(let footer): turnFooterContent(footer)
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
            inlineCode(block.text).font(DS.Font.prose).lineSpacing(DS.Space.badgeV)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level):
            Text(block.text)
                .font(level == 1 ? DS.Font.proseTitle : level == 2 ? DS.Font.title : DS.Font.proseHeading)
                .padding(.top, DS.Space.s)
                .fixedSize(horizontal: false, vertical: true)
        case .quote:
            HStack(alignment: .top, spacing: DS.Space.m) {
                RoundedRectangle.rounded(DS.Radius.chip).fill(DS.Palette.border)
                    .frame(width: DS.Size.proseQuoteRule)
                inlineCode(block.text).font(DS.Font.prose).foregroundStyle(DS.Palette.textSecondary)
            }.fixedSize(horizontal: false, vertical: true)
        case .list:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(Array(block.list.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text(line.marker).foregroundStyle(DS.Palette.textSecondary)
                            .frame(minWidth: DS.Space.l, alignment: .trailing)
                        inlineCode(line.text).frame(maxWidth: .infinity, alignment: .leading)
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
                ChatTable(rows: block.table, codeFill: chrome.color(.raised), narrowest: tableColumnMinimum, limit: tableColumnMaximum,
                          available: rowWidth > 0 ? ChatReadingColumn.textWidth(in: rowWidth) : .infinity)
                if block.hasOmittedContent {
                    Button("Open full table") { actions.selectText(block.source) }
                        .font(DS.Font.caption).frame(minHeight: DS.Size.touchTarget)
                }
            }
        case .separator:
            Hairline(style: DS.Palette.separator).padding(.vertical, DS.Space.s)
        case .plain:
            Text(block.text).font(DS.Font.literal).fixedSize(horizontal: false, vertical: true)
        case .image(let path):
            ChatInlineImage(path: path, height: ChatImageBox.height, loader: actions.loadImage)
        }
    }

    @ViewBuilder private func itemContent(_ item: TimelineItem) -> some View {
        switch item.body {
        case .user(let user): userContent(item, user: user)
        case .assistant(let assistant):
            Text(verbatim: assistant.text).font(DS.Font.prose).fixedSize(horizontal: false, vertical: true)
        case .tool(let tool): toolContent(item, tool: tool)
        case .thinking(let thinking): thinkingContent(thinking)
        case .plan(let plan): planContent(plan)
        case .notice(let notice): noticeContent(notice)
        case .turnEnd(let end): turnEndContent(item, end: end)
        case .longText(let longText): longTextContent(item, longText: longText)
        }
    }

    private func userContent(_ item: TimelineItem, user: TimelineUser) -> some View {
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            if user.queued {
                Label("Queued", systemImage: "clock").font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            let images = ChatImages.paths(attachments: user.attachments).prefix(4)
            if !images.isEmpty {
                HStack(spacing: DS.Space.s) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, path in
                        ChatInlineImage(path: path, height: ChatImageBox.attachmentHeight, loader: actions.loadImage,
                                        alignment: .trailing)
                    }
                }
            }
            VStack(alignment: .trailing, spacing: 0) {
                bubble(row.preview ?? user.text)
                promptFooter(item, text: user.text, canResend: !user.queued && row.preview == nil)
            }
            if row.preview != nil {
                Button("Read full prompt") { actions.selectText(user.text) }.font(DS.Font.caption)
            }
            ForEach(Array(user.attachments.filter { !images.contains($0.path) }.prefix(12).enumerated()), id: \.offset) { _, attachment in
                Label((attachment.path as NSString).lastPathComponent, systemImage: "paperclip")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if user.attachments.count > 12 {
                Button("View all \(user.attachments.count) attachments") {
                    actions.selectText(user.attachments.map(\.path).joined(separator: "\n"))
                }.font(DS.Font.caption)
            }
        }.frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, DS.Space.xxxl)
    }

    /// A prompt on a light bubble: the ink at the sidebar strength on dark chrome, a step deeper
    /// on light chrome, where 5 % barely shows on paper.
    private func bubble(_ text: String) -> some View {
        Text(verbatim: text).font(DS.Font.prose).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.l).padding(.vertical, DS.Space.m)
            .background(chrome.scheme == .light ? DS.Palette.raised : DS.Palette.sidebar,
                        in: .rect(cornerRadius: DS.Radius.card, style: .continuous))
    }

    /// Under a prompt, quietly and close to it: where it came from, when, and Copy and Send again.
    /// The words read at text contrast, the glyphs a step quieter; each glyph still answers a
    /// 44 pt touch, reaching up over the bubble's edge.
    private func promptFooter(_ item: TimelineItem, text: String, canResend: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            Group {
                if let time = ChatItemPresentation.promptTime(item.at) {
                    Text(verbatim: item.origin == .terminal ? "From Terminal · " + time : time).monospacedDigit()
                } else if item.origin == .terminal {
                    Text("From Terminal")
                }
            }
            .foregroundStyle(DS.Palette.textSecondary)
            footerButton("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            if canResend, let resend = actions.resend {
                footerButton("Send again", systemImage: "arrow.clockwise") { resend(text) }
                    .accessibilityIdentifier("chat-resend")
            }
        }
        .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
        .frame(height: DS.Size.touchTarget)
        .padding(.top, -DS.Space.m).padding(.bottom, -DS.Space.s)
        .buttonStyle(.plain)
    }

    private func footerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
                .frame(width: DS.Space.l, height: DS.Size.touchTarget)
                .contentShape(Rectangle().inset(by: -DS.Space.m))
        }
    }

    private var fromTerminal: some View {
        Text("From Terminal").font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
    }

    private func thinkingContent(_ thinking: TimelineThinking) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.gap10) {
            thinkingHeader(ChatItemPresentation.thinkingTitle(thinking), hasText: ChatItemPresentation.hasThinkingText(thinking))
            if isExpanded, ChatItemPresentation.hasThinkingText(thinking), let text = thinking.text {
                Text(verbatim: row.preview ?? text).font(DS.Font.proseSecondary)
                    .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                if row.preview != nil { Button("Read all") { actions.selectText(text) }.font(DS.Font.caption) }
            }
        }
    }

    private func thinkingHeader(_ title: String, hasText: Bool) -> some View {
        Button(action: toggle) {
            HStack(spacing: DS.Space.xs) {
                Text(title)
                if hasText {
                    Image(systemName: "chevron.right").font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                Spacer(minLength: DS.Space.s)
            }.font(DS.Font.proseSecondary).foregroundStyle(DS.Palette.textSecondary)
                .frame(minHeight: DS.Size.touchTarget)
        }.buttonStyle(ChatRowButtonStyle()).disabled(!hasText)
            .accessibilityValue(hasText ? (isExpanded ? "Expanded" : "Collapsed") : "")
    }

    @ViewBuilder private func longTextContent(_ item: TimelineItem, longText: TimelineLongText) -> some View {
        let text = row.preview ?? longText.content.preview
        switch longText.role {
        case .known(.user):
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                bubble(text)
                if item.origin == .terminal { fromTerminal }
            }.frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, DS.Space.xxxl)
        case .known(.thinking):
            VStack(alignment: .leading, spacing: DS.Space.gap10) {
                thinkingHeader("Thinking", hasText: !text.isEmpty)
                if isExpanded, !text.isEmpty {
                    Text(verbatim: text).font(DS.Font.proseSecondary)
                        .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .known(.assistant), .unknown:
            Text(verbatim: text).font(DS.Font.prose).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func showAllContent(_ longText: TimelineLongText) -> some View {
        let alignment: Alignment = longText.role == .known(.user) ? .trailing : .leading
        Group {
            if actions.readsToolDetails {
                Button(ChatLongText.showAllTitle(longText.content), systemImage: "text.alignleft") {
                    actions.showLongText(longText)
                }.accessibilityIdentifier("chat-long-text-show-all")
            } else {
                Text(verbatim: ChatLongText.previewNote(longText.content))
            }
        }
        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: alignment)
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
        }.padding(DS.Space.l).background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.pane, style: .continuous))
    }

    private func noticeContent(_ notice: TimelineNotice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text(verbatim: row.preview ?? notice.text).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: notice.kind == .known(.error) ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(notice.kind == .known(.error) ? DS.Palette.error : DS.Palette.info)
            }.font(DS.Font.proseSecondary)
            if row.preview != nil { Button("Read all") { actions.selectText(notice.text) }.font(DS.Font.caption) }
        }
    }

    private func turnEndContent(_ item: TimelineItem, end: TimelineTurnEnd) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(verbatim: ChatItemPresentation.turnSummary(end))
            Spacer(minLength: 0)
            if actions.supportsDiffs {
                Button("Changes", systemImage: "plus.forwardslash.minus") { actions.showDiff(.turn(item.turn)) }
            }
        }.font(DS.Font.meta).foregroundStyle(DS.Palette.textSecondary)
    }

    private func toolGroupContent(_ group: ChatToolGroup) -> some View {
        let tools = group.tools.compactMap { item -> TimelineTool? in
            if case .tool(let tool) = item.body { tool } else { nil }
        }
        return Button(action: toggle) {
            HStack(spacing: DS.Space.xs) {
                ChatToolGlyph(symbol: ChatToolGroups.symbol(tools), isFailed: false)
                    .padding(.trailing, DS.Space.xs)
                ViewThatFits(in: .horizontal) {
                    ForEach(ChatToolGroups.shortenedActions(tools), id: \.self) { actions in
                        Text(verbatim: actions).lineLimit(1).truncationMode(.tail)
                    }
                }
                .foregroundStyle(DS.Palette.textSecondary)
                if let outcome = ChatToolGroups.outcome(tools) {
                    Text(verbatim: "(" + outcome + ")").foregroundStyle(DS.Palette.error)
                        .lineLimit(1).fixedSize()
                }
                if group.additions + group.deletions > 0 {
                    Group {
                        Text(verbatim: "+\(group.additions)").foregroundStyle(DS.Palette.done)
                        Text(verbatim: "−\(group.deletions)").foregroundStyle(DS.Palette.error)
                    }
                    .font(DS.Font.meta).fixedSize()
                }
                Image(systemName: "chevron.right").font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }.font(DS.Font.proseSecondary).frame(minHeight: DS.Size.touchTarget)
        }
        .buttonStyle(ChatRowButtonStyle())
        .accessibilityLabel(group.summary)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("chat-tool-group")
    }

    /// The verb at text contrast, then what it acted on, quieter and cut in the middle so a
    /// path keeps its file name and a command its end.
    private func toolLine(_ line: ChatToolLine) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(verbatim: line.verb).foregroundStyle(DS.Palette.text).lineLimit(1).fixedSize()
            if !line.detail.isEmpty {
                Text(verbatim: line.detail).foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .font(DS.Font.proseSecondary)
    }

    private func turnSummaryContent(_ summary: ChatTurnSummary) -> some View {
        Button(action: toggle) {
            HStack(spacing: DS.Space.xs) {
                ChatToolGlyph(symbol: "list.bullet.indent", isFailed: false)
                    .padding(.trailing, DS.Space.xs)
                ViewThatFits(in: .horizontal) {
                    ForEach(summary.shortenedLabels, id: \.self) { label in
                        Text(verbatim: label).lineLimit(1).truncationMode(.tail)
                    }
                }
                .foregroundStyle(DS.Palette.textSecondary)
                if let outcome = summary.outcome {
                    Text(verbatim: "(" + outcome + ")").foregroundStyle(DS.Palette.error)
                        .lineLimit(1).fixedSize()
                }
                Image(systemName: "chevron.right").font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }.font(DS.Font.proseSecondary).frame(minHeight: DS.Size.touchTarget)
        }
        .buttonStyle(ChatRowButtonStyle())
        .accessibilityLabel(summary.label)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows what the agent did before this reply")
        .accessibilityIdentifier("chat-turn-summary")
    }

    /// Copy for the reply first, where the eye lands after reading it, then the turn's time.
    private func turnFooterContent(_ footer: ChatTurnFooter) -> some View {
        HStack(spacing: DS.Space.s) {
            ChatCopyButton(title: "Copy reply", text: footer.markdown)
                .padding(.trailing, -DS.Space.m)
                .accessibilityIdentifier("chat-turn-copy")
            if let end = footer.end {
                Text(verbatim: ChatItemPresentation.turnSummary(end))
            }
            Spacer(minLength: 0)
            if footer.end != nil, actions.supportsDiffs {
                Button("Changes", systemImage: "plus.forwardslash.minus") { actions.showDiff(.turn(footer.turn)) }
            }
        }
        .font(DS.Font.meta).foregroundStyle(DS.Palette.textSecondary)
        .padding(.leading, -DS.Space.m)
    }

    private func toolContent(_ item: TimelineItem, tool: TimelineTool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.gap10) {
            let line = ChatToolLine(tool, workingDirectory: actions.workingDirectory)
            Button(action: toggle) {
                HStack(spacing: DS.Space.s) {
                    ChatToolGlyph(symbol: line.symbol, isFailed: tool.status == .known(.failed))
                    toolLine(line)
                        .shimmering(tool.status == .known(.running), text: line.text)
                    Group {
                        if let state = ChatItemPresentation.toolStateLabel(tool) {
                            Text(state).foregroundStyle(tool.status == .known(.interrupted) ? DS.Palette.textSecondary : DS.Palette.error)
                        } else if !tool.diff.isEmpty {
                            Text("+\(tool.diff.reduce(UInt64(0)) { $0 + UInt64($1.additions) })")
                                .foregroundStyle(DS.Palette.done)
                            Text("−\(tool.diff.reduce(UInt64(0)) { $0 + UInt64($1.deletions) })")
                                .foregroundStyle(DS.Palette.error)
                        } else if let time = tool.durationMs { Text(duration(time)).foregroundStyle(DS.Palette.textTertiary) }
                    }
                    .fixedSize()
                    Image(systemName: "chevron.right")
                        .font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }.font(DS.Font.meta).frame(minHeight: DS.Size.touchTarget)
            }.buttonStyle(ChatRowButtonStyle())
                .accessibilityLabel(line.text)
                .accessibilityValue([ChatItemPresentation.toolStatus(tool), tool.durationMs.map(duration),
                                     isExpanded ? "Expanded" : "Collapsed"].compactMap { $0 }.joined(separator: ", "))
            if let path = row.imagePath {
                ChatInlineImage(path: path, height: ChatImageBox.height, loader: actions.loadImage)
            }
            if isExpanded {
                if let input = ChatItemPresentation.toolInputSummary(tool) {
                    Text(verbatim: input).font(DS.Font.literalSmall)
                        .foregroundStyle(DS.Palette.textSecondary).lineLimit(8)
                }
                if let output = tool.output, !output.preview.isEmpty {
                    ScrollView(.horizontal) {
                        Text(verbatim: output.preview.split(separator: "\n", omittingEmptySubsequences: false).suffix(12).joined(separator: "\n"))
                            .font(DS.Font.literalSmall).foregroundStyle(terminalTheme.foreground)
                            .fixedSize(horizontal: true, vertical: true).padding(DS.Space.m)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: CGFloat(min(output.preview.split(separator: "\n", omittingEmptySubsequences: false).count, 12)) * outputLineHeight + 2 * DS.Space.m)
                    .background(terminalTheme.codeSurface, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
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
            .clipShape(.rect(cornerRadius: DS.Radius.pane, style: .continuous))
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

    private var selectionContent: String? {
        if case .showAll = row.content { return "preview" }
        if case .item(let item) = row.content, case .longText = item.body { return "preview" }
        guard case .item(let item) = row.content, case .tool(let tool) = item.body else { return nil }
        let input = !tool.input.isEmpty, output = tool.output?.preview.isEmpty == false
        return input && output ? "input and output preview" : input ? "input" : output ? "output preview" : "tool summary"
    }

    var copyTitle: String {
        selectionContent.map { "Copy " + $0 } ?? (usesRawMarkdownSelection ? "Copy raw Markdown" : "Copy")
    }
    var selectionTitle: String {
        selectionContent.map { "Select " + $0 } ?? (usesRawMarkdownSelection ? "Select raw Markdown" : "Select Text")
    }

    var plainText: String {
        switch row.content {
        case .markdown(let block): markdownSelectionText(block)
        case .omitted: ChatRenderLimits.omittedMessage
        case .showAll(let value): value.content.preview
        case .toolGroup(let group): group.summary
        case .turnSummary(let summary): summary.label
        case .turnFooter(let footer): footer.markdown
        case .item(let item):
            switch item.body {
            case .user(let value): value.text
            case .assistant(let value): value.text
            case .thinking(let value): ChatItemPresentation.hasThinkingText(value) ? value.text ?? "" : ChatItemPresentation.thinkingTitle(value)
            case .tool(let value): toolSelectionText(value)
            case .plan(let value): value.entries.map(\.text).joined(separator: "\n")
            case .notice(let value): value.text
            case .turnEnd(let value): "Worked for \(duration(value.durationMs))"
            case .longText(let value): value.content.preview
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

    private func inlineCode(_ text: AttributedString) -> some View {
        ChatInlineCode.text(text).modifier(ChatCodeFill(fill: ChatInlineCode.hasCode(text) ? chrome.color(.raised) : nil))
    }
}

/// A tool's kind as a small glyph in a fixed column, so the lines' words align.
private struct ChatToolGlyph: View {
    let symbol: String
    let isFailed: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(DS.Font.caption)
            .frame(width: DS.Space.l)
            .foregroundStyle(isFailed ? DS.Palette.error : DS.Palette.textTertiary)
            .accessibilityHidden(true)
    }
}

/// Copy as an icon that answers with a checkmark for a moment, so the tap reads as done.
struct ChatCopyButton: View {
    let title: LocalizedStringKey
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(title, systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: DS.Size.touchTarget, height: DS.Size.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(DS.Motion.micro, value: copied)
        .accessibilityValue(copied ? "Copied" : "")
    }
}

private struct ChatRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minHeight: DS.Size.touchTarget).contentShape(.rect)
            .background(RoundedRectangle.rounded(DS.Radius.control)
                .fill(DS.Palette.selection.opacity(configuration.isPressed ? 1 : 0)))
            .animation(reduceMotion ? nil : DS.Motion.micro, value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

extension EnvironmentValues {
    /// The width Chat lays its rows out in: a table fits itself to it before it scrolls.
    @Entry var chatRowWidth: CGFloat = 0
}

/// A Markdown table as an open grid: a separator under the header and hairlines between rows,
/// no box. Columns fit the reading column first; a table that still does not fit scrolls
/// sideways with its cut edge faded.
private struct ChatTable: View {
    let rows: [[AttributedString]]
    let codeFill: Color
    let narrowest: CGFloat
    let limit: CGFloat
    let available: CGFloat
    @State private var edges = ChatScrollEdges()

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .fixedSize(horizontal: false, vertical: true)
                .onScrollGeometryChange(for: ChatScrollEdges.self) { geometry in
                    ChatScrollEdges(offset: geometry.contentOffset.x, content: geometry.contentSize.width,
                                    container: geometry.containerSize.width)
                } action: { _, edges in self.edges = edges }
                .chatEdgeFade(edges)
        }
    }

    private var grid: some View {
        ChatTableGrid(narrowest: narrowest, limit: limit, spacing: DS.Space.l, available: available) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                if index > 0 {
                    Hairline(style: index == 1 ? DS.Palette.separator : DS.Palette.hairline).chatTableRule()
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    ChatInlineCode.text(cell).fontWeight(index == 0 ? .semibold : .regular)
                        .modifier(ChatCodeFill(fill: ChatInlineCode.hasCode(cell) ? codeFill : nil))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, DS.Space.s)
                }
            }
        }
        .font(DS.Font.proseSecondary)
    }
}

/// Which ends of a sideways scroller have more to show.
struct ChatScrollEdges: Equatable {
    var leading = false
    var trailing = false

    init() {}

    init(offset: CGFloat, content: CGFloat, container: CGFloat) {
        leading = offset > 0.5
        trailing = offset + container < content - 0.5
    }
}

extension View {
    /// A soft fade where content runs past an edge, so a cut line reads as more to scroll to.
    func chatEdgeFade(_ edges: ChatScrollEdges) -> some View {
        mask {
            HStack(spacing: 0) {
                // style-exempt: a mask, only its alpha counts
                LinearGradient(colors: [edges.leading ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: DS.Size.proseEdgeFade)
                Rectangle()
                // style-exempt: a mask, only its alpha counts
                LinearGradient(colors: [.black, edges.trailing ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: DS.Size.proseEdgeFade)
            }
        }
    }
}

/// A fenced code block: a quiet header with the language and Copy over the code in the
/// terminal's font, on the terminal's own background lifted a step so it reads as a surface.
private struct ChatCodeBlock: View {
    let code: ChatCodeSnippet
    let language: String?
    let showAll: () -> Void
    @Environment(\.terminalTheme) private var terminalTheme
    @AppStorage(TerminalPreferences.Key.fontSize) private var fontSize = TerminalPreferences.Default.fontSize
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1
    @State private var edges = ChatScrollEdges()

    private var lineHeight: CGFloat {
        let font = TerminalFont.regular.flatMap { UIFont(name: $0, size: fontSize) }
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ceil((font.lineHeight + DS.Space.xxs) * scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: language?.isEmpty == false ? language ?? "" : "code")
                .font(DS.Font.literalSmall).foregroundStyle(DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) { copyButton }
                .padding(.leading, DS.Space.m).padding(.top, DS.Space.m)
            ScrollView(.horizontal) {
                Text(ChatCodeStyler.text(code, theme: terminalTheme, increasedContrast: contrast == .increased))
                    .font(TerminalFont.font(size: fontSize, relativeTo: .callout)).lineSpacing(DS.Space.xxs * scale)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, DS.Space.m).padding(.bottom, DS.Space.m)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: ChatScrollEdges.self) { geometry in
                ChatScrollEdges(offset: geometry.contentOffset.x, content: geometry.contentSize.width,
                                container: geometry.containerSize.width)
            } action: { _, edges in self.edges = edges }
            .chatEdgeFade(edges)
            .frame(height: CGFloat(code.visibleLineCount) * lineHeight + DS.Space.m)
            if code.isTruncated {
                Hairline(style: DS.Palette.hairline)
                Button(code.lineCount == 1 ? "Show full code" : "Show all \(code.lineCount) lines", action: showAll)
                    .font(DS.Font.caption).padding(.horizontal, DS.Space.m)
                    .frame(maxWidth: .infinity, minHeight: DS.Size.touchTarget, alignment: .leading)
                    .foregroundStyle(DS.Palette.textSecondary).background(DS.Palette.sidebar)
            }
        }
        .background(terminalTheme.codeSurface, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .clipShape(.rect(cornerRadius: DS.Radius.control, style: .continuous))
    }

    /// A 44 pt target centred on the label's line, reaching over the code's first line so the
    /// label can sit close above the code.
    private var copyButton: some View {
        Button { UIPasteboard.general.string = code.text } label: {
            Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.Size.touchTarget, height: DS.Size.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat-code-copy")
    }
}
#endif
