import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Agent Inbox: every agent across hosts, grouped "Needs you" / "Running" / "Finished", with
/// approve, deny and reply inline so most requests never need the terminal (04-mobile-ux C4).
/// Finished turns, failures and long commands come from each host's attention feed; what the
/// inbox shows counts as seen on every device.
struct InboxView: View {
    let feed: any AgentFeed
    var onLaunch: () -> Void = {}
    /// A plain shell tab (the window's current host); when set, + is a menu: New Terminal, New Agent.
    var onNewTerminal: (() -> Void)?
    /// Jump to the agent's pane (default: the feed's own `open`).
    var onOpen: ((AgentItem) -> Void)?

    @Environment(WindowModel.self) private var model
    @Environment(\.chrome) private var chrome
    @State private var approvedCount = 0
    @State private var deniedCount = 0

    var body: some View {
        let items = feed.items
        Group {
            if items.isEmpty {
                EmptyState(
                    "Nothing Needs You", systemImage: "tray",
                    message: "Agents on your hosts report here when they need approval, ask a question, or finish."
                ) {
                    Button("Start an Agent", action: onLaunch)
                        .buttonStyle(.primaryGlass)
                        .disabled(feed.launchHosts.isEmpty && !LaunchOptions.mock)
                }
            } else {
                list(items)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { InboxUsageStrip() }
        .chromeContent()
        .navigationTitle("Inbox")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let onNewTerminal {
                    // + is a terminal first (the plain shell), then an agent.
                    Menu {
                        Button("New Terminal", systemImage: "terminal", action: onNewTerminal)
                            .accessibilityIdentifier("inbox-new-terminal")
                        Button("New Agent", systemImage: "sparkle", action: onLaunch)
                            .accessibilityIdentifier("inbox-new-agent")
                    } label: {
                        Label("New", systemImage: "plus")
                    } primaryAction: {
                        onNewTerminal()
                    }
                    // Toolbar controls are monochrome (DESIGN.md), never the accent.
                    .tint(.primary)
                    .accessibilityIdentifier("inbox-new")
                } else {
                    Button("New Agent", systemImage: "plus", action: onLaunch)
                        .accessibilityIdentifier("inbox-new-agent")
                }
            }
        }
        #if os(iOS)
        // The hidden terminal keeps the keyboard (and its key bar) otherwise; the inbox has its
        // own fields.
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        #endif
        .sensoryFeedback(DS.Haptic.success, trigger: approvedCount)
        .sensoryFeedback(DS.Haptic.attention, trigger: deniedCount)
        .task(id: feed.unseenByHost.values.reduce(0, +)) {
            // Seen once it has been on screen a moment (the dots fade, every device's badge clears).
            guard !feed.unseenByHost.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.overlay) { feed.markSeen() }
        }
    }

    /// "2 need you · 3 new on studio".
    private var subtitle: String {
        let needYou = feed.items.filter(\.state.needsYou).count
        return [needYou > 0 ? "\(needYou) need\(needYou == 1 ? "s" : "") you" : nil, unseenLine.isEmpty ? nil : unseenLine]
            .compactMap(\.self).joined(separator: " · ")
    }

    /// "3 new · studio 2, devbox 1".
    private var unseenLine: String {
        let unseen = feed.unseenByHost.sorted { $0.key < $1.key }
        guard !unseen.isEmpty else { return "" }
        let total = unseen.reduce(0) { $0 + $1.value }
        if unseen.count == 1 { return "\(total) new on \(unseen[0].key)" }
        return "\(total) new · " + unseen.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private func list(_ items: [AgentItem]) -> some View {
        let needsYou = items.filter(\.state.needsYou).sorted { $0.since > $1.since }
        let running = items.filter { $0.state == .working }.sorted { $0.since > $1.since }
        let finished = items.filter { $0.state == .done || $0.state == .idle }.sorted { $0.since > $1.since }
        // list on the base, hairlines inset to the text column.
        return List {
            section("Needs you", needsYou)
            section("Running", running)
            section("Finished", finished)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DS.Palette.base)
        .animation(DS.Motion.snappy, value: items)
        .accessibilityIdentifier("inbox-list")
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AgentItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    InboxRow(
                        item: item,
                        open: { open(item) },
                        approve: {
                            approvedCount += 1
                            withAnimation(DS.Motion.snappy) { feed.approve(item.id) }
                        },
                        deny: {
                            deniedCount += 1
                            withAnimation(DS.Motion.snappy) { feed.deny(item.id) }
                        },
                        reply: { text in
                            do {
                                try await feed.reply(item.id, text: text)
                                model.toasts.show(Toast("Sent to \(item.agent.title)", systemImage: "arrow.up.circle.fill", style: .success))
                                return true
                            } catch {
                                model.toasts.show(Toast("Couldn't reply: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
                                return false
                            }
                        })
                    .swipeActions(edge: .trailing) {
                        Button("Mark Done", systemImage: "checkmark") {
                            withAnimation(DS.Motion.snappy) { feed.markDone(item.id) }
                        }
                        .tint(DS.Palette.done)
                    }
                    .contextMenu {
                        if item.paneId != nil {
                            Button("Open Pane", systemImage: "rectangle.on.rectangle") { open(item) }
                        }
                        Button(item.isCommand ? "Copy Command" : "Copy Prompt", systemImage: "doc.on.doc") { copy(item.prompt) }
                        if let summary = item.summary {
                            Button("Copy Summary", systemImage: "text.quote") { copy(summary) }
                        }
                        Divider()
                        Button("Mark Done", systemImage: "checkmark") {
                            withAnimation(DS.Motion.snappy) { feed.markDone(item.id) }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("inbox-\(item.id)")
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(chrome.hairline)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in InboxRow.textColumn }
                }
            } header: {
                SectionTitle(title, count: items.count)
                    .padding(.top, DS.Space.s)
            }
        }
    }

    private func open(_ item: AgentItem) {
        if let onOpen { onOpen(item) } else { feed.open(item.id) }
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// One agent: status glyph, agent and where it runs, age, prompt, then what it needs.
private struct InboxRow: View {
    let item: AgentItem
    let open: () -> Void
    let approve: () -> Void
    let deny: () -> Void
    /// Sends a reply; true when it went through (the composer closes).
    let reply: (String) async -> Bool

    @State private var isReplying = false
    @State private var isSending = false
    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool

    static let glyphSlot: CGFloat = 16
    static let textColumn: CGFloat = glyphSlot + DS.Space.m

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            glyph
                .frame(width: Self.glyphSlot, height: 20)
            VStack(alignment: .leading, spacing: DS.Space.row) {
                header
                Text(verbatim: item.prompt)
                    .font(item.isCommand ? DS.Font.literal : DS.Font.rowSubtitle)
                    .foregroundStyle(item.request == nil ? .secondary : .primary)
                    .lineLimit(item.request == nil ? 1 : 2)
                request
                if let summary = item.summary {
                    Text(verbatim: summary)
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(item.state == .error ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(.secondary))
                        .lineLimit(3)
                }
                if isReplying {
                    composer
                } else if item.canReply, item.request == nil, item.state != .working {
                    HStack {
                        Spacer()
                        replyButton("Reply…")
                    }
                }
            }
        }
        .padding(.vertical, DS.Space.row)
        .contentShape(.rect)
        .onTapGesture(count: 2) { if item.paneId != nil { open() } }
    }

    @ViewBuilder private var glyph: some View {
        if item.isCommand {
            Image(systemName: item.state == .error ? "xmark.circle" : "checkmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(item.state == .error ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(.secondary))
        } else {
            StatusIndicator(item.state, size: 14)
                .opacity(item.state.needsYou ? 1 : DS.Opacity.mutedGlyph)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.row) {
            HStack(spacing: DS.Space.row) {
                // The agent's mark before its name (the state glyph leads the row).
                if !item.isCommand {
                    ProgramMark(item.agent.identity)
                        .foregroundStyle(.primary)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
                Text(item.isCommand ? "Command" : item.agent.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Text("\(item.hostName) · \(item.sessionTitle)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.s)
            if item.unseen {
                Circle()
                    .fill(DS.Palette.accent)
                    .frame(width: 7, height: 7)
                    .transition(.opacity)
                    .accessibilityLabel("New")
            }
            TimelineView(.periodic(from: .now, by: item.state == .working ? 1 : 30)) { context in
                Text(age(at: context.date))
                    .font(DS.Font.meta)
                    .foregroundStyle(item.state == .working ? AnyShapeStyle(item.state.color) : AnyShapeStyle(.secondary))
            }
            if item.paneId != nil {
                Button("Open Pane", systemImage: "arrow.up.right", action: open)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bar)
                    .controlSize(.small)
                    .help("Open the pane")
                    .accessibilityIdentifier("inbox-open-\(item.id)")
            }
        }
    }

    @ViewBuilder private var request: some View {
        switch item.request {
        case .permission(let tool, let detail)?:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Text(verbatim: detail)
                        .font(DS.Font.literal)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
                HStack(spacing: DS.Space.s) {
                    Spacer()
                    Button("Deny", action: deny)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("inbox-deny-\(item.id)")
                    Button("Approve", action: approve)
                        .buttonStyle(.primaryGlass)
                        .accessibilityIdentifier("inbox-approve-\(item.id)")
                }
                #if os(macOS)
                .controlSize(.small)
                #endif
            }
        case .question(let question)?:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(verbatim: question)
                    .font(DS.Font.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if !isReplying {
                    HStack {
                        Spacer()
                        replyButton("Reply…")
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private func replyButton(_ title: String) -> some View {
        Button(title) {
            withAnimation(DS.Motion.snappy) { isReplying = true }
            isComposerFocused = true
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .accessibilityIdentifier("inbox-reply-\(item.id)")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            TextField("Reply to \(item.agent.title)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, DS.Space.s + 2)
                .padding(.vertical, DS.Space.s)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
                .focused($isComposerFocused)
                .onSubmit(send)
                .submitLabel(.send)
                // Return sends (a chat, not a document); ⇧Return is a new line.
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    send()
                    return .handled
                }
                .onKeyPress(.escape) {
                    withAnimation(DS.Motion.snappy) { isReplying = false }
                    return .handled
                }
                .accessibilityIdentifier("inbox-composer")
                // Focus once the field exists (setting it with `isReplying` is too early).
                .task { isComposerFocused = true }
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .buttonStyle(.primaryGlass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .accessibilityIdentifier("inbox-send")
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        Task {
            let sent = await reply(text)
            isSending = false
            if sent {
                draft = ""
                withAnimation(DS.Motion.snappy) { isReplying = false }
            }
        }
    }

    private func age(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(item.since)))
        if item.state == .working {
            return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
        }
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
