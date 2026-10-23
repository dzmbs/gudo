import DesignSystem
import SwiftUI

/// The agent toasts (`AgentToasts`): cards under the toolbar at the trailing edge (top on iPhone),
/// newest on top. Holding the pointer or a finger on them keeps them; while the pointer is over a
/// card, ↩ approves and Esc (⌘.) denies it, as in the Inbox.
struct AgentToastStack: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let toasts = model.agentToasts
        let compact = model.widthBucket == .compact
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            ForEach(Array(toasts.cards.enumerated()), id: \.element.id) { index, card in
                AgentToastCard(card: card, isNewest: index == 0)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: compact ? .top : .trailing).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
        .frame(maxWidth: compact ? .infinity : 380)
        .padding(.horizontal, compact ? DS.Space.s : DS.Space.m)
        // Under the toolbar's band (its trailing controls stay reachable).
        .padding(.top, compact ? DS.Space.s : 58)
        .onHover { toasts.hold($0) }
        // A finger on a card holds the stack too.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in toasts.hold(true) }
                .onEnded { _ in toasts.hold(false) })
        .animation(DS.Motion.indicator, value: toasts.cards.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-toasts")
    }
}

private struct AgentToastCard: View {
    let card: AgentToasts.Card
    let isNewest: Bool
    @Environment(WindowModel.self) private var model
    @State private var isHovered = false

    private var item: AgentItem { card.item }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            mark
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                header
                if let detail { detail }
                actions
                    .padding(.top, DS.Space.xxs)
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingPanel(cornerRadius: DS.Radius.panel)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button("Dismiss", systemImage: "xmark") {
                    withAnimation(DS.Motion.overlay) { model.agentToasts.dismiss(card.id) }
                }
                .help("Dismiss")
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption2.weight(.bold))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 20, height: 20)
                .background(DS.Palette.raised, in: .circle)
                .overlay(Circle().strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
                .offset(x: 6, y: -6)
                .transition(.opacity)
                .accessibilityIdentifier("agent-toast-dismiss")
            }
        }
        .onHover { hovering in withAnimation(DS.Motion.overlay) { isHovered = hovering } }
        .chromeContent()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-toast-\(item.id)")
    }

    private var mark: some View {
        ProgramMark(item.agent.identity, size: 22)
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
            .overlay(alignment: .bottomTrailing) {
                StatusIndicator(state, size: 14)
                    .background(Circle().fill(DS.Palette.overlay).padding(-1.5))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }

    private var state: AgentState {
        switch card.kind {
        case .needsYou: .blocked
        case .finished: .done
        case .failed: .error
        }
    }

    private var headline: String {
        switch card.kind {
        case .needsYou:
            if case .question? = item.request { "\(item.agent.title) has a question" } else { "\(item.agent.title) needs you" }
        case .finished: "\(item.agent.title) finished"
        case .failed: "\(item.agent.title) failed"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(item.hostName) · \(item.sessionTitle)")
                .font(.footnote)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: AnyView? {
        switch item.request {
        case .permission(_, let detail)?:
            AnyView(
                Text(verbatim: detail)
                    .font(DS.Font.literalSmall)
                    .lineLimit(2)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.field).strokeBorder(DS.Palette.hairline, lineWidth: 0.5)))
        case .question(let question)?:
            AnyView(Text(verbatim: question).font(DS.Font.rowSubtitle).lineLimit(2))
        case nil:
            (item.summary ?? (item.prompt == "Working…" ? nil : item.prompt)).map { line in
                AnyView(Text(verbatim: line)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(card.kind == .failed ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(DS.Palette.textSecondary))
                    .lineLimit(2))
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: DS.Space.s) {
            if isNewest, card.kind == .needsYou {
                ShortcutLabel(["⇧", "⌘", "A"])
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .help("Jump to the agent waiting longest (⇧⌘A)")
            }
            Spacer(minLength: 0)
            if case .permission? = item.request {
                Button("Deny") { decide(allow: false) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(isHovered ? .cancelAction : nil)
                    .help("Deny (Esc)")
                    .accessibilityIdentifier("agent-toast-deny-\(item.id)")
                Button("Approve") { decide(allow: true) }
                    .buttonStyle(.primaryGlass)
                    .keyboardShortcut(isHovered ? .defaultAction : nil)
                    .help("Approve (↩)")
                    .accessibilityIdentifier("agent-toast-approve-\(item.id)")
            } else {
                Button("Open") { open() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(isHovered ? .defaultAction : nil)
                    .help("Show the agent's pane (↩)")
                    .accessibilityIdentifier("agent-toast-open-\(item.id)")
            }
        }
        .controlSize(.small)
        // Esc on iPad keyboards without one.
        .background {
            if isHovered, case .permission? = item.request {
                Button("Deny") { decide(allow: false) }
                    .keyboardShortcut(".", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    private func decide(allow: Bool) {
        withAnimation(DS.Motion.snappy) {
            if allow { model.agents.approve(item.id) } else { model.agents.deny(item.id) }
            model.agentToasts.dismiss(card.id)
        }
    }

    private func open() {
        model.agentToasts.dismiss(card.id)
        model.agents.open(item.id)
    }
}
