import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Agent Inbox: every agent across hosts, grouped "Needs you" / "Running" / "Finished", with
/// approve, deny and reply inline so most requests never need the terminal (04-mobile-ux C4).
struct InboxView: View {
    let feed: any AgentFeed
    var onLaunch: () -> Void = {}
    /// Jump to the agent's pane.
    var onOpen: (AgentItem) -> Void = { _ in }

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
                        .buttonStyle(.glassProminent)
                }
            } else {
                list(items)
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Agent", systemImage: "plus", action: onLaunch)
                    .accessibilityIdentifier("inbox-new-agent")
            }
        }
        .sensoryFeedback(DS.Haptic.success, trigger: approvedCount)
        .sensoryFeedback(DS.Haptic.attention, trigger: deniedCount)
    }

    private func list(_ items: [AgentItem]) -> some View {
        let needsYou = items.filter(\.state.needsYou).sorted { $0.since > $1.since }
        let running = items.filter { $0.state == .working }.sorted { $0.since > $1.since }
        let finished = items.filter { $0.state == .done }.sorted { $0.since > $1.since }
        return List {
            section("Needs you", needsYou)
            section("Running", running)
            section("Finished", finished)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .animation(DS.Motion.snappy, value: items)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AgentItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    InboxRow(
                        item: item,
                        approve: {
                            approvedCount += 1
                            withAnimation(DS.Motion.snappy) { feed.approve(item.id) }
                        },
                        deny: {
                            deniedCount += 1
                            withAnimation(DS.Motion.snappy) { feed.deny(item.id) }
                        },
                        reply: { text in
                            withAnimation(DS.Motion.snappy) { feed.reply(item.id, text: text) }
                        })
                    .swipeActions(edge: .trailing) {
                        Button("Mark Done", systemImage: "checkmark") {
                            withAnimation(DS.Motion.snappy) { feed.markDone(item.id) }
                        }
                        .tint(DS.Palette.done)
                    }
                    .contextMenu {
                        Button("Open Pane", systemImage: "rectangle.on.rectangle") { onOpen(item) }
                        Button("Copy Prompt", systemImage: "doc.on.doc") { copy(item.prompt) }
                        Divider()
                        Button("Mark Done", systemImage: "checkmark") {
                            withAnimation(DS.Motion.snappy) { feed.markDone(item.id) }
                        }
                    }
                    .accessibilityIdentifier("inbox-\(item.id)")
                }
            } header: {
                SectionTitle(title, count: items.count)
            }
        }
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
    let approve: () -> Void
    let deny: () -> Void
    let reply: (String) -> Void

    @State private var isReplying = false
    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            StatusIndicator(item.state, size: 14)
                .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: DS.Space.xs + 2) {
                header
                Text(item.prompt)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(item.request == nil ? .secondary : .primary)
                    .lineLimit(item.request == nil ? 1 : 2)
                request
                if let summary = item.summary {
                    Text(summary)
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(item.state == .error ? DS.Palette.error : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(item.agent.title)
                .font(DS.Font.rowTitleEmphasis)
                .lineLimit(1)
                .layoutPriority(1)
            Text("\(item.hostName) · \(item.sessionTitle)")
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.s)
            TimelineView(.periodic(from: .now, by: item.state == .working ? 1 : 30)) { context in
                Text(age(at: context.date))
                    .font(DS.Font.meta)
                    .foregroundStyle(item.state == .working ? item.state.color : .secondary)
            }
        }
    }

    @ViewBuilder private var request: some View {
        switch item.request {
        case .permission(let tool, let detail)?:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(detail)
                        .font(DS.Font.literal)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.Space.s + 2)
                .padding(.vertical, DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: .rect(cornerRadius: DS.Radius.control))
                HStack(spacing: DS.Space.s) {
                    Spacer()
                    Button("Deny", action: deny)
                        .buttonStyle(.glass)
                    Button("Approve", action: approve)
                        .buttonStyle(.glassProminent)
                }
                .controlSize(.small)
            }
        case .question(let question)?:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(question)
                    .font(DS.Font.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if isReplying {
                    composer
                } else {
                    HStack {
                        Spacer()
                        Button("Reply…") {
                            withAnimation(DS.Motion.snappy) { isReplying = true }
                            isComposerFocused = true
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            TextField("Reply to \(item.agent.title)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, DS.Space.s + 2)
                .padding(.vertical, DS.Space.s)
                .background(.fill.quaternary, in: .rect(cornerRadius: DS.Radius.control))
                .focused($isComposerFocused)
                .onSubmit(send)
                .onKeyPress(.escape) {
                    withAnimation(DS.Motion.snappy) { isReplying = false }
                    return .handled
                }
            Button("Send", systemImage: "arrow.up", action: send)
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply(text)
        draft = ""
        isReplying = false
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

/// Start Claude Code or Codex on a connected host with a first prompt.
struct LaunchAgentSheet: View {
    let feed: any AgentFeed
    let hosts: [HostSummary]

    @Environment(\.dismiss) private var dismiss
    @State private var agent = AgentKind.claude
    @State private var hostID: String?
    @State private var prompt = ""
    @FocusState private var isPromptFocused: Bool

    private var connected: [HostSummary] { hosts.filter { $0.connection == .connected } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    ForEach([AgentKind.claude, .codex], id: \.self) { kind in
                        Button { agent = kind } label: {
                            HStack(spacing: DS.Space.m) {
                                Image(systemName: kind.systemImage)
                                    .font(.title3)
                                    .foregroundStyle(agent == kind ? DS.Palette.accent : .secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title).font(DS.Font.rowTitleEmphasis)
                                    Text(kind == .claude ? "Anthropic’s coding agent" : "OpenAI’s coding agent")
                                        .font(DS.Font.rowSubtitle)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if agent == kind {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(DS.Palette.accent)
                                }
                            }
                            .padding(.vertical, DS.Space.xs)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(agent == kind ? .isSelected : [])
                    }
                }
                Section {
                    Picker("Host", selection: $hostID) {
                        ForEach(connected) { host in
                            Text(host.name).tag(Optional(host.id))
                        }
                    }
                    .disabled(connected.isEmpty)
                } footer: {
                    if connected.isEmpty {
                        Text("No host is connected. Connect one in Hosts first.")
                    }
                }
                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                        .focused($isPromptFocused)
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("What should \(agent.title) do?")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityIdentifier("launch-prompt")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start", action: start)
                        .disabled(!canStart)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .onAppear {
                hostID = hostID ?? connected.first?.id
                isPromptFocused = true
            }
        }
        #if os(iOS)
        .phoneDetents([.large])
        #else
        .frame(minWidth: 460, idealWidth: 500, minHeight: 480)
        #endif
    }

    private var canStart: Bool {
        hostID != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() {
        guard canStart, let host = connected.first(where: { $0.id == hostID }) else { return }
        feed.launch(agent, host: host.name, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}
