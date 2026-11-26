import DesignSystem
import SwiftUI

/// The agents' cards, stacked newest nearest the edge of the window's toast corner.
struct AgentToastStack: View {
    var position = ToastPosition.standard
    @Environment(WindowModel.self) private var model
    @GestureState private var isTouching = false

    var body: some View {
        let toasts = model.agentToasts
        let compact = model.widthBucket == .compact
        let fromTop = position.edge == .top
        VStack(alignment: position.horizontalAlignment, spacing: DS.Space.s) {
            if !model.isPresentation {
                ForEach(model.app.crossHost.requests) { request in
                    CrossHostCardView(request: request) { request, choice in model.app.crossHost.answer(request, choice) }
                        .motionTransition(.toast(from: position.stackEdge))
                }
            }
            ForEach(Array(toasts.cards.enumerated()), id: \.element.id) { index, card in
                AgentToastCard(card: card, isNewest: index == toasts.cards.count - 1, edge: position.edge)
                    .motionTransition(.toast(from: position.stackEdge))
            }
        }
        .frame(maxWidth: compact ? .infinity : 380)
        .onHover { toasts.hold($0) }
        // Gesture state resets when the system cancels the touch, so a hold always ends.
        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isTouching) { _, touching, _ in touching = true })
        .onChange(of: isTouching) { _, touching in toasts.hold(touching) }
        .toastStack(position: position, bottomInset: fromTop ? DS.Space.l : PortOfferBanner.bottomInset(model)
            + (model.ports.offer != nil && !model.editorHasKeys ? PortOfferBanner.height + DS.Space.s : 0),
            topInset: PaneHeader.height + DS.Space.l)
        .animation(DS.Motion.micro, value: toasts.cards.map(\.id))
        .animation(DS.Motion.micro, value: model.app.crossHost.requests.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-toasts")
    }
}

private struct AgentToastCard: View {
    let card: AgentToasts.Card
    let isNewest: Bool
    /// The edge the stack sits on, which a swipe may send the card toward.
    let edge: Edge
    @Environment(WindowModel.self) private var model
    @Environment(\.chromeAccessibility) private var accessibility
    @State private var isHovered = false
    @State private var dragOffset = CGSize.zero
    @GestureState private var isDragging = false
    @State private var isDismissing = false

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
            if showsDismiss {
                dismissButton
                    .offset(x: 6, y: -6)
                    .motionTransition(.pill())
            }
        }
        .onHover { hovering in withAnimation(DS.Motion.standard) { isHovered = hovering } }
        .chromeContent()
        .offset(swipeOffset)
        .opacity(1 - min(0.6, max(abs(swipeOffset.width), abs(swipeOffset.height)) / 240))
        .simultaneousGesture(swipe)
        // A drag the system cancels never ends; the card settles back all the same.
        .onChange(of: isDragging) { _, dragging in
            if !dragging, !isDismissing, dragOffset != .zero { withAnimation(accessibility.travel(DS.Motion.standard)) { dragOffset = .zero } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Dismiss") { dismiss() }
        .accessibilityIdentifier("agent-toast-\(item.id)")
    }

    /// Always on a touch screen, where nothing hovers; on the Mac with the pointer over the card.
    private var showsDismiss: Bool {
        #if os(iOS)
        true
        #else
        isHovered
        #endif
    }

    private static let dismissDisc: CGFloat = 20

    private var dismissButton: some View {
        Button("Dismiss", systemImage: "xmark") { dismiss() }
            .help("Dismiss")
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.caption2.weight(.bold))
            .foregroundStyle(DS.Palette.textSecondary)
            .frame(width: Self.dismissDisc, height: Self.dismissDisc)
            .background(DS.Palette.raised, in: .circle)
            .hairlineBorder(Circle(), style: DS.Palette.hairline)
            .contentShape(.rect.inset(by: -(DS.Size.touchTarget - Self.dismissDisc) / 2))
            .accessibilityLabel("Dismiss \(headline)")
            .accessibilityIdentifier("agent-toast-dismiss")
    }

    /// The card follows the finger sideways, and toward its edge but not away from it.
    private var swipeOffset: CGSize {
        let vertical = edge == .top ? min(0, dragOffset.height) : max(0, dragOffset.height)
        return CGSize(width: dragOffset.width, height: vertical)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                if AgentToasts.swipeDismisses(translation: value.translation, predicted: value.predictedEndTranslation, edge: edge) {
                    dismiss()
                } else {
                    withAnimation(accessibility.travel(DS.Motion.standard)) { dragOffset = .zero }
                }
            }
    }

    private func dismiss() {
        isDismissing = true
        withAnimation(accessibility.travel(DS.Motion.standard)) { model.agentToasts.dismiss(card.id) }
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
