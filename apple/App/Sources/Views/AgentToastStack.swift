import DesignSystem
import SwiftUI

/// The agents' cards, stacked newest nearest the edge of the window's toast corner.
struct AgentToastStack: View {
    var position = ToastPosition.standard
    @Environment(WindowModel.self) private var model

    var body: some View {
        let toasts = model.agentToasts
        let compact = model.widthBucket == .compact
        let fromTop = position.edge == .top
        VStack(alignment: position.horizontalAlignment, spacing: DS.Space.s) {
            ForEach(Array(toasts.cards.enumerated()), id: \.element.id) { index, card in
                AgentToastCard(card: card, isNewest: index == toasts.cards.count - 1)
                    .motionTransition(.toast(from: position.stackEdge))
            }
        }
        .frame(maxWidth: compact ? .infinity : 380)
        .toastObstacle()
        .padding(.horizontal, DS.Space.l)
        .padding(fromTop ? .top : .bottom, fromTop ? PaneHeader.height + DS.Space.l : PortOfferBanner.bottomInset(model)
            + (model.ports.offer != nil && !model.editorHasKeys ? PortOfferBanner.height + DS.Space.s : 0))
        .onHover { toasts.hold($0) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in toasts.hold(true) }
                .onEnded { _ in toasts.hold(false) })
        .animation(DS.Motion.micro, value: toasts.cards.map(\.id))
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
                    withAnimation(DS.Motion.standard) { model.agentToasts.dismiss(card.id) }
                }
                .help("Dismiss")
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption2.weight(.bold))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 20, height: 20)
                .background(DS.Palette.raised, in: .circle)
                .hairlineBorder(Circle(), style: DS.Palette.hairline)
                .offset(x: 6, y: -6)
                .motionTransition(.pill())
                .accessibilityIdentifier("agent-toast-dismiss")
            }
        }
        .onHover { hovering in withAnimation(DS.Motion.standard) { isHovered = hovering } }
        .chromeContent()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-toast-\(item.id)")
    }

    private var mark: some View {
        ProgramMark(item.identity, size: 22)
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
            if item.drive, case .permission(let want, _)? = item.request {
                want
            } else if case .question? = item.request { "\(item.title) has a question" } else { "\(item.title) needs you" }
        case .finished: "\(item.title) finished"
        case .failed: "\(item.title) failed"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text([item.hostName, item.sessionTitle].filter { !$0.isEmpty && !$0.contains("|") }.joined(separator: " · "))
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
                    .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.field, style: .continuous))
                    .hairlineBorder(RoundedRectangle.rounded(DS.Radius.field), style: DS.Palette.hairline))
        case .question?:
            AgentToasts.summary(for: item).map { line in
                AnyView(Text(verbatim: line).font(DS.Font.rowSubtitle).lineLimit(1))
            }
        case nil:
            AgentToasts.summary(for: item).map { line in
                AnyView(Text(verbatim: line)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(card.kind == .failed ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(DS.Palette.textSecondary))
                    .lineLimit(1))
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
                if model.agents.canApproveAlways(item.id) {
                    Button("Always") { approveAlways() }
                        .buttonStyle(.glass)
                        .help("Approve, and don't ask again about this tool")
                        .accessibilityIdentifier("agent-toast-always-\(item.id)")
                }
                if item.drive {
                    Button("This Pane") { allowForPane() }
                        .buttonStyle(.glass)
                        .help("Allow for this pane until it closes")
                        .accessibilityIdentifier("agent-toast-allow-pane-\(item.id)")
                }
                Button(item.drive ? "Allow Once" : "Approve") { decide(allow: true) }
                    .buttonStyle(.primaryGlass)
                    .keyboardShortcut(isHovered ? .defaultAction : nil)
                    .help(item.drive ? "Allow this one action (↩)" : "Approve (↩)")
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
        withAnimation(DS.Motion.standard) {
            if allow { model.agents.approve(item.id) } else { model.agents.deny(item.id) }
            model.agentToasts.dismiss(card.id)
        }
    }

    private func approveAlways() {
        withAnimation(DS.Motion.standard) {
            model.agents.approveAlways(item.id)
            model.agentToasts.dismiss(card.id)
        }
    }

    private func allowForPane() {
        withAnimation(DS.Motion.standard) {
            model.agents.allowForPane(item.id)
            model.agentToasts.dismiss(card.id)
        }
    }

    private func open() {
        model.agentToasts.dismiss(card.id)
        model.agents.open(item.id)
    }
}
