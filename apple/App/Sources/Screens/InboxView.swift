import DesignSystem
import SwiftUI
#if canImport(UIKit)
import GameController
import UIKit
#else
import AppKit
#endif

enum InboxFilter: String, CaseIterable, Identifiable {
    case all, needsYou, running, unread, errors
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .needsYou: "Needs You"
        case .running: "Running"
        case .unread: "Unread"
        case .errors: "Errors"
        }
    }

    func includes(_ item: AgentItem) -> Bool {
        switch self {
        case .all: true
        case .needsYou: item.state == .blocked
        case .running: item.state == .working
        case .unread: item.unseen
        case .errors: item.state == .error
        }
    }

    /// What the list says when nothing matches.
    var emptyTitle: String {
        switch self {
        case .all: "Nothing Needs You"
        case .needsYou: "No Agent Is Waiting"
        case .running: "No Agent Is Working"
        case .unread: "All Caught Up"
        case .errors: "No Failures"
        }
    }
}

/// Agent Inbox: every agent across hosts, grouped "Needs you" / "Running" / "Finished", with
/// approve, deny and reply inline so most requests never need the terminal (04-mobile-ux C4).
/// Finished turns, failures and long commands come from each host's attention feed; what the
/// inbox shows counts as seen on every device.
///
/// denies, E edits the command before approving where the agent takes edited input, ⇧↩ approves
/// all like it for the rest of the task.
struct InboxView: View {
    let feed: any AgentFeed
    var onLaunch: () -> Void = {}
    /// A plain shell tab (the window's current host); when set, + is a menu: New Terminal, New Agent.
    var onNewTerminal: (() -> Void)?
    /// Jump to the agent's pane (default: the feed's own `open`).
    var onOpen: ((AgentItem) -> Void)?

    @Environment(WindowModel.self) private var model
    @Environment(\.chrome) private var chrome
    @SceneStorage("inboxFilter") private var filter = InboxFilter.all
    @State private var approvedCount = 0
    @State private var deniedCount = 0
    /// The row the keyboard acts on.
    @State private var focused: AgentItem.ID?
    /// The row whose command is being edited before approval.
    @State private var editing: AgentItem.ID?
    /// Rows whose text field has the keyboard: the list's keys step aside.
    @State private var typing: Set<AgentItem.ID> = []

    var body: some View {
        let items = feed.items
        let shown = items.filter(filter.includes)
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
            } else if shown.isEmpty {
                EmptyState(filter.emptyTitle, systemImage: "line.3.horizontal.decrease.circle", message: "Nothing in the Inbox matches this filter.") {
                    Button("Show All") { withAnimation(DS.Motion.snappy) { filter = .all } }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("inbox-show-all")
                }
            } else {
                list(shown)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !items.isEmpty {
                InboxFilterBar(selection: $filter, counts: counts(items))
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { InboxUsageStrip() }
        .background { keys(order(shown)) }
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
        // On iPad the key catcher (`InboxKeyCatcher`) takes the keyboard from the hidden terminal
        // (and its key bar).
        .onAppear {
            // With a keyboard at hand the first row starts focused, so ↩ answers at once.
            if focused == nil, Self.hasKeyboard { focused = order(shown).first?.id }
        }
        .onChange(of: filter) { focused = Self.hasKeyboard ? order(feed.items.filter(filter.includes)).first?.id : nil }
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

    /// A hardware keyboard is attached (always on the Mac).
    static var hasKeyboard: Bool {
        #if os(iOS)
        GCKeyboardProbe.isAttached
        #else
        true
        #endif
    }

    private func counts(_ items: [AgentItem]) -> [InboxFilter: Int] {
        Dictionary(uniqueKeysWithValues: InboxFilter.allCases.map { filter in (filter, items.filter(filter.includes).count) })
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

    /// The sections in display order.
    private func sections(_ items: [AgentItem]) -> [(title: String, items: [AgentItem])] {
        let needsYou = items.filter(\.state.needsYou).sorted { $0.since > $1.since }
        let running = items.filter { $0.state == .working }.sorted { $0.since > $1.since }
        let finished = items.filter { $0.state == .done || $0.state == .idle }.sorted { $0.since > $1.since }
        return [("Needs you", needsYou), ("Running", running), ("Finished", finished)].filter { !$0.items.isEmpty }
    }

    /// Every row in display order (what ↑/↓ walk).
    private func order(_ items: [AgentItem]) -> [AgentItem] {
        sections(items).flatMap(\.items)
    }

    private func list(_ items: [AgentItem]) -> some View {
        // list on the base, hairlines inset to the text column.
        ScrollViewReader { proxy in
            List {
                ForEach(sections(items), id: \.title) { section in
                    Section {
                        ForEach(section.items) { item in row(item) }
                    } header: {
                        SectionTitle(section.title, count: section.items.count)
                            .padding(.top, DS.Space.s)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DS.Palette.base)
            .animation(DS.Motion.snappy, value: items)
            .onChange(of: focused) { _, id in
                guard let id else { return }
                withAnimation(DS.Motion.snappy) { proxy.scrollTo(id) }
            }
            .accessibilityIdentifier("inbox-list")
        }
    }

    private func row(_ item: AgentItem) -> some View {
        let isFocused = focused == item.id
        return InboxRow(
            item: item,
            options: feed.approvalOptions(item.id),
            rules: feed.autoApprovals(item.id),
            isFocused: isFocused,
            isEditing: Binding(get: { editing == item.id }, set: { editing = $0 ? item.id : nil }),
            open: { open(item) },
            approve: { approve(item) },
            deny: { deny(item) },
            approveEdited: { input in approveEdited(item, input: input) },
            approveAll: { approveAll(item) },
            revoke: { rule in revoke(item, rule: rule) },
            setTyping: { isTyping in
                if isTyping { typing.insert(item.id) } else { typing.remove(item.id) }
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
            .id(item.id)
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
            .accessibilityValue(isFocused ? "focused" : "")
            // The keyboard's row: the selection fill, inset like the sidebar's rows.
            .listRowBackground(
                RoundedRectangle(cornerRadius: DS.Radius.pane)
                    .fill(isFocused ? AnyShapeStyle(DS.Palette.selectedFill) : AnyShapeStyle(Color.clear))
                    .padding(.horizontal, DS.Space.xs))
            .listRowSeparatorTint(chrome.hairline)
            .alignmentGuide(.listRowSeparatorLeading) { _ in InboxRow.textColumn }
    }

    // MARK: Actions

    private func approve(_ item: AgentItem) {
        approvedCount += 1
        advance(from: item)
        withAnimation(DS.Motion.snappy) { feed.approve(item.id) }
        model.agentToasts.dismiss(item: item.id)
    }

    private func deny(_ item: AgentItem) {
        deniedCount += 1
        advance(from: item)
        withAnimation(DS.Motion.snappy) { feed.deny(item.id) }
        model.agentToasts.dismiss(item: item.id)
    }

    private func approveEdited(_ item: AgentItem, input: String) {
        Task {
            do {
                try await feed.approveEdited(item.id, input: input)
                approvedCount += 1
                editing = nil
                advance(from: item)
                model.agentToasts.dismiss(item: item.id)
            } catch {
                model.toasts.show(Toast("Couldn't approve: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }

    private func approveAll(_ item: AgentItem) {
        Task {
            do {
                try await feed.approveAllLikeThis(item.id)
                approvedCount += 1
                advance(from: item)
                model.agentToasts.dismiss(item: item.id)
                if let like = feed.approvalOptions(item.id)?.likeThis ?? feed.autoApprovals(item.id).last?.label {
                    model.toasts.show(Toast("Approving “\(like)” for this task", systemImage: "checkmark.seal.fill", style: .success))
                }
            } catch {
                model.toasts.show(Toast("Couldn't approve: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }

    private func revoke(_ item: AgentItem, rule: AgentAutoApproval) {
        Task {
            do {
                try await feed.revokeAutoApproval(item.id, rule: rule.id)
                model.toasts.show(Toast("Stopped approving “\(rule.label)”", systemImage: "xmark.seal", style: .neutral))
            } catch {
                model.toasts.show(Toast("Couldn't revoke: \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
            }
        }
    }

    /// After answering a row, the keyboard moves on to the next one (the answered row changes
    /// section as the agent resumes).
    private func advance(from item: AgentItem) {
        guard focused == item.id else { return }
        let rows = order(feed.items.filter(filter.includes)).filter { $0.id != item.id }
        let all = order(feed.items.filter(filter.includes))
        let index = all.firstIndex { $0.id == item.id } ?? 0
        focused = rows.indices.contains(index) ? rows[index].id : rows.last?.id
    }

    private func open(_ item: AgentItem) {
        model.agentToasts.dismiss(item: item.id)
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

    // MARK: Keys

    /// The list's keys, as shortcuts (they work on iPad hardware keyboards without a focused
    /// view). They step aside while a row's text field has the keyboard.
    @ViewBuilder private func keys(_ rows: [AgentItem]) -> some View {
        let active = typing.isEmpty && editing == nil
        #if os(iOS)
        InboxKeyCatcher(active: active) { key in perform(key, rows: rows) }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        #else
        Group {
            key("Previous", .upArrow) { perform(.previous, rows: rows) }
            key("Next", .downArrow) { perform(.next, rows: rows) }
            key("Approve or Open", .return) { perform(.approve, rows: rows) }
            key("Deny", .escape) { perform(.deny, rows: rows) }
            key("Deny", ".", modifiers: .command) { perform(.deny, rows: rows) }
            key("Edit, Then Approve", "e") { perform(.edit, rows: rows) }
            key("Approve All Like This", .return, modifiers: .shift) { perform(.approveAll, rows: rows) }
        }
        .disabled(!active)
        #endif
    }

    private func perform(_ key: InboxKey, rows: [AgentItem]) {
        guard typing.isEmpty, editing == nil else { return }
        switch key {
        case .previous: move(-1, in: rows)
        case .next: move(1, in: rows)
        case .approve: activate(rows)
        case .approveAll: approveAll(focusedIn: rows)
        case .deny: deny(focusedRequestIn: rows)
        case .edit:
            guard let current = rows.first(where: { $0.id == focused }), case .permission? = current.request,
                  feed.approvalOptions(current.id)?.editableInput != nil
            else { return }
            editing = current.id
        }
    }

    /// ↩: approves the focused request, or opens the focused agent's pane; with nothing
    /// focused, focuses the first row.
    private func activate(_ rows: [AgentItem]) {
        guard let current = rows.first(where: { $0.id == focused }) else {
            focused = rows.first?.id
            return
        }
        if case .permission? = current.request { approve(current) } else if current.paneId != nil { open(current) }
    }

    private func deny(focusedRequestIn rows: [AgentItem]) {
        guard let current = rows.first(where: { $0.id == focused }), case .permission? = current.request else { return }
        deny(current)
    }

    private func approveAll(focusedIn rows: [AgentItem]) {
        guard let current = rows.first(where: { $0.id == focused }), case .permission? = current.request,
              feed.approvalOptions(current.id)?.likeThis != nil
        else { return }
        approveAll(current)
    }

    private func key(_ title: String, _ key: KeyEquivalent, modifiers: EventModifiers = [], action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    private func move(_ step: Int, in rows: [AgentItem]) {
        guard !rows.isEmpty else { return }
        guard let index = rows.firstIndex(where: { $0.id == focused }) else {
            focused = (step > 0 ? rows.first : rows.last)?.id
            return
        }
        focused = rows[min(max(index + step, 0), rows.count - 1)].id
    }
}

#if os(iOS)
/// Whether a hardware keyboard is attached (GameController's coalesced keyboard).
enum GCKeyboardProbe {
    static var isAttached: Bool { GCKeyboard.coalesced != nil }
}
#endif

/// All / Needs You / Running / Unread / Errors, each with its count: a segmented track, the
/// selected segment a raised pill that slides (the system's segmented control, on the theme).
private struct InboxFilterBar: View {
    @Binding var selection: InboxFilter
    let counts: [InboxFilter: Int]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InboxFilter.allCases) { filter in
                let count = counts[filter] ?? 0
                let isSelected = filter == selection
                Button {
                    withAnimation(DS.Motion.snappy) { selection = filter }
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Text(filter.title)
                            .font(.footnote.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                        if filter != .all, count > 0 {
                            Text("\(count)")
                                .font(DS.Font.meta)
                                .foregroundStyle(filter == .needsYou ? AnyShapeStyle(DS.Palette.attention)
                                    : filter == .errors ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(.secondary))
                                .contentTransition(.numericText())
                        }
                    }
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.row - 1)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: DS.Radius.control - 2)
                                .fill(DS.Palette.overlay)
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control - 2).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(count > 0 && filter != .all ? "\(filter.title), \(count)" : filter.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("inbox-filter-\(filter.rawValue)")
            }
        }
        .padding(2)
        .background(DS.Palette.hoverFill, in: .rect(cornerRadius: DS.Radius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox-filters")
    }
}

/// One agent: status glyph, agent and where it runs, age, prompt, then what it needs.
private struct InboxRow: View {
    let item: AgentItem
    let options: AgentApprovalOptions?
    let rules: [AgentAutoApproval]
    let isFocused: Bool
    @Binding var isEditing: Bool
    let open: () -> Void
    let approve: () -> Void
    let deny: () -> Void
    let approveEdited: (String) -> Void
    let approveAll: () -> Void
    let revoke: (AgentAutoApproval) -> Void
    /// The row's text field took or gave up the keyboard.
    let setTyping: (Bool) -> Void
    /// Sends a reply; true when it went through (the composer closes).
    let reply: (String) async -> Bool

    @State private var isReplying = false
    @State private var isSending = false
    @State private var draft = ""
    @State private var edited = ""
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isEditFocused: Bool

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
                ForEach(rules) { rule in AutoApprovalChip(rule: rule) { revoke(rule) } }
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
        .onChange(of: isReplying || isEditing) { _, typing in setTyping(typing) }
        .onChange(of: isEditing) { _, editing in
            if editing { edited = options?.editableInput ?? "" }
        }
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
                let title = item.isCommand ? "Command" : item.agent.title
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .shimmering(item.state == .working, text: title)
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
                if isEditing {
                    editor(tool: tool)
                } else {
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
                    verbs
                }
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

    /// auto-approve in its menu). The focused row shows its keys.
    private var verbs: some View {
        HStack(spacing: DS.Space.s) {
            Spacer()
            if options?.editableInput != nil {
                Button { isEditing = true } label: { verb("Edit", key: "E") }
                    .buttonStyle(.glass)
                    .help("Edit the command, then approve (E)")
                    .accessibilityIdentifier("inbox-edit-\(item.id)")
            }
            Button(action: deny) { verb("Deny", key: "esc") }
                .buttonStyle(.glass)
                .help("Deny (Esc)")
                .accessibilityIdentifier("inbox-deny-\(item.id)")
            HStack(spacing: 1) {
                Button(action: approve) { verb("Approve", key: "↩") }
                    .buttonStyle(.primaryGlass)
                    .help("Approve (↩)")
                    .accessibilityIdentifier("inbox-approve-\(item.id)")
                if let like = options?.likeThis {
                    Menu {
                        Button("Approve All Like This for This Task", systemImage: "checkmark.seal", action: approveAll)
                            .accessibilityIdentifier("inbox-approve-all-\(item.id)")
                        Text("“\(like)”, for \(AgentAutoApproval.minutes / 60) hour or \(AgentAutoApproval.turns) turns. Revoke it here any time.")
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help("More ways to approve (⇧↩ approves all like this)")
                    .accessibilityLabel("More Approve Options")
                    .accessibilityIdentifier("inbox-approve-menu-\(item.id)")
                }
            }
        }
        #if os(macOS)
        .controlSize(.small)
        #endif
    }

    /// A verb with its key beside it on the focused row (the keyboard's row).
    private func verb(_ title: String, key: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(title)
            if isFocused {
                Text(key)
                    .font(DS.Font.badge)
                    .opacity(0.6)
                    .transition(.opacity)
            }
        }
    }

    /// Edit, then approve: the command in an editable field; ↩ approves the edited command,
    /// Esc (⌘.) puts it back.
    private func editor(tool: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(tool) · edited")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                TextField("Command", text: $edited, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Font.literal)
                    .lineLimit(1...6)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($isEditFocused)
                    .onSubmit(submitEdit)
                    .onKeyPress(.return, phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        submitEdit()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        cancelEdit()
                        return .handled
                    }
                    // Return in a multi-line field types a newline (software keyboards, pasted
                    // text): a command is one line, so a newline means "approve this".
                    .onChange(of: edited) { _, text in
                        guard text.contains(where: \.isNewline) else { return }
                        edited = text.filter { !$0.isNewline }
                        submitEdit()
                    }
                    .accessibilityIdentifier("inbox-edit-field")
                    .task { isEditFocused = true }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).strokeBorder(DS.Palette.accent, lineWidth: 1))
            HStack(spacing: DS.Space.s) {
                Spacer()
                Button(action: cancelEdit) { verb("Cancel", key: "esc") }
                    .buttonStyle(.glass)
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("inbox-edit-cancel")
                Button(action: submitEdit) { verb("Approve Edited", key: "↩") }
                    .buttonStyle(.primaryGlass)
                    .disabled(edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("inbox-edit-approve")
            }
            #if os(macOS)
            .controlSize(.small)
            #endif
        }
        .transition(.opacity)
    }

    private func submitEdit() {
        let text = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        approveEdited(text)
    }

    private func cancelEdit() {
        withAnimation(DS.Motion.snappy) { isEditing = false }
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

/// A standing "approve all like this" on the agent's row: what it covers, how long and how many
/// turns it has left, and Revoke.
private struct AutoApprovalChip: View {
    let rule: AgentAutoApproval
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(DS.Palette.done)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Auto-approving \(Text(verbatim: rule.label).font(DS.Font.literalSmall)) · \(remaining(at: context.date))")
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DS.Space.xs)
            Button("Revoke", action: revoke)
                .font(DS.Font.meta.weight(.medium))
                .buttonStyle(.bar)
                .controlSize(.small)
                .help("Stop approving these for this task (granted by \(rule.grantedBy))")
                .accessibilityIdentifier("inbox-revoke-\(rule.id)")
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(DS.Palette.done.opacity(0.10), in: .rect(cornerRadius: DS.Radius.chip))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox-auto-approval")
    }

    /// "52m · 9 turns left".
    private func remaining(at now: Date) -> String {
        let minutes = max(0, Int(rule.expiresAt.timeIntervalSince(now) / 60))
        let time = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return "\(time) · \(rule.turnsLeft) turn\(rule.turnsLeft == 1 ? "" : "s") left"
    }
}
