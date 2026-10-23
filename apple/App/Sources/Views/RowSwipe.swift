import DesignSystem
import SwiftUI

// Swipe, long-press and right-click actions for rows outside a system `List` (the sidebar is
// drawn by hand): the system's swipe on touch, the same actions in the context
// menu and to VoiceOver, and a confirmation before what cannot be undone.

/// The one row of a list whose actions are showing: opening another closes it.
@Observable
final class RowSwipeState {
    var open: String?
}

extension View {
    /// A row's actions (`RowActions`) on a swipe, in its context menu after `menu`'s own items,
    /// and as accessibility actions. `name` goes in the confirmation's question.
    func rowActions(
        _ actions: RowActions, id: String, name: String,
        perform: @escaping (RowAction) -> Void,
        @ViewBuilder menu: () -> some View = { EmptyView() }
    ) -> some View {
        modifier(RowActionsModifier(actions: actions, id: id, name: name, inList: false, perform: perform, menu: menu()))
    }

    /// The same for a row of a system `List`: its own swipe actions (trackpad swipes on the Mac too).
    func listRowActions(
        _ actions: RowActions, name: String,
        perform: @escaping (RowAction) -> Void,
        @ViewBuilder menu: () -> some View = { EmptyView() }
    ) -> some View {
        modifier(RowActionsModifier(actions: actions, id: "", name: name, inList: true, perform: perform, menu: menu()))
    }
}

/// A menu item for a row action: its title, symbol and role.
struct RowActionButton: View {
    let action: RowAction
    let perform: (RowAction) -> Void

    var body: some View {
        Button(action.title, systemImage: action.systemImage, role: action.isDestructive ? .destructive : nil) { perform(action) }
            .accessibilityIdentifier("menu-\(action.rawValue)")
    }
}

private struct RowActionsModifier<Menu: View>: ViewModifier {
    let actions: RowActions
    let id: String
    let name: String
    let inList: Bool
    let perform: (RowAction) -> Void
    let menu: Menu
    @State private var confirming: RowAction?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                menu
                if !actions.all.isEmpty {
                    Divider()
                    // Destructive last, the outermost swipe action at the very end.
                    ForEach(actions.leading + actions.trailing.reversed(), id: \.self) { action in
                        RowActionButton(action: action, perform: request)
                    }
                }
            }
            .accessibilityActions {
                ForEach(actions.all, id: \.self) { action in
                    Button(action.title) { request(action) }
                }
            }
            .swipeActions(edge: .leading) { if inList { swipeButtons(actions.leading) } }
            .swipeActions(edge: .trailing) { if inList { swipeButtons(actions.trailing) } }
            #if os(iOS)
            .modifier(SwipeContainer(actions: inList ? RowActions() : actions, id: id, request: request))
            #endif
            .confirmationDialog(
                confirming.map { $0.confirmation(name).title } ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { action in
                Button(action.title.replacingOccurrences(of: "…", with: ""), role: .destructive) { perform(action) }
                    .accessibilityIdentifier("confirm-\(action.rawValue)")
            } message: { action in
                Text(action.confirmation(name).message)
            }
    }

    /// No destructive role: a `List` would take the row out before a confirmation is answered.
    private func swipeButtons(_ edge: [RowAction]) -> some View {
        ForEach(edge, id: \.self) { action in
            Button(action.shortTitle, systemImage: action.systemImage) { request(action) }
                .tint(action.tint.color)
                .accessibilityLabel(action.title)
                .accessibilityIdentifier(action.identifier)
        }
    }

    private func request(_ action: RowAction) {
        if actions.needsConfirmation(action) {
            confirming = action
        } else {
            withAnimation(DS.Motion.snappy) { perform(action) }
        }
    }
}

extension RowTint {
    /// The system colours, so a swipe looks like every other app's.
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .indigo: .indigo
        }
    }
}

extension RowAction {
    var swipe: SwipeAction {
        SwipeAction(id: identifier, title: shortTitle, label: title, systemImage: systemImage, tint: tint.color)
    }
}

#if os(iOS)
/// The system's swipe: the row slides to show its actions beside it; past most of its width the
/// outermost one takes the whole row and runs on release. A tap anywhere on an open row closes it.
private struct SwipeContainer: ViewModifier {
    let actions: RowActions
    let id: String
    let request: (RowAction) -> Void
    @Environment(RowSwipeState.self) private var shared: RowSwipeState?
    @State private var offset: CGFloat = 0
    @State private var start: CGFloat?
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 0
    @State private var armed = false
    @State private var isHorizontal: Bool?

    /// The share of the row's width past which a swipe runs its outermost action.
    private static let fullSwipe: CGFloat = 0.6

    func body(content: Content) -> some View {
        if actions.all.isEmpty {
            content
        } else {
            content
                .overlay {
                    if offset != 0, start == nil {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { close() }
                            .accessibilityHidden(true)
                    }
                }
                .offset(x: offset)
                .background(alignment: .trailing) {
                    if offset < 0 { buttons(actions.trailing, trailing: true, revealed: -offset) }
                }
                .background(alignment: .leading) {
                    if offset > 0 { buttons(actions.leading, trailing: false, revealed: offset) }
                }
                .clipped()
                .onGeometryChange(for: CGSize.self, of: \.size) { size in
                    width = size.width
                    height = size.height
                }
                // Beside the row's own tap, long press and drag; a swipe that starts mostly
                // vertical is the list's scroll and is left alone.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            if isHorizontal == nil { isHorizontal = abs(value.translation.width) > abs(value.translation.height) }
                            if isHorizontal == true { changed(value.translation.width) }
                        }
                        .onEnded { value in
                            if isHorizontal == true { ended(value.translation.width, value.velocity.width) }
                            isHorizontal = nil
                        })
                .sensoryFeedback(DS.Haptic.armed, trigger: armed) { _, now in now }
                .onChange(of: shared?.open) { _, open in
                    if open != id, offset != 0, start == nil { withAnimation(DS.Motion.swipe) { offset = 0 } }
                }
        }
    }

    /// The edge's tray; `edge` lists the outermost first, the tray wants it last.
    private func buttons(_ edge: [RowAction], trailing: Bool, revealed: CGFloat) -> some View {
        SwipeActionTray(
            edge.reversed().map(\.swipe), edge: trailing ? .trailing : .leading, revealed: revealed,
            rowHeight: height, armed: armed
        ) { swipe in
            guard let action = edge.first(where: { $0.identifier == swipe.id }) else { return }
            close()
            request(action)
        }
    }

    private func reveal(_ edge: [RowAction]) -> CGFloat {
        SwipeActionTray.width(for: edge.count, rowHeight: height)
    }

    private func changed(_ x: CGFloat) {
        if start == nil {
            start = offset
            shared?.open = id
        }
        var next = (start ?? 0) + x
        if actions.leading.isEmpty { next = min(0, next) }
        if actions.trailing.isEmpty { next = max(0, next) }
        offset = max(-width, min(width, next))
        let edge = offset < 0 ? actions.trailing : actions.leading
        armed = !edge.isEmpty && abs(offset) > width * Self.fullSwipe
    }

    private func ended(_ x: CGFloat, _ velocity: CGFloat) {
        defer { start = nil }
        let edge = offset < 0 ? actions.trailing : actions.leading
        if armed, let action = edge.first {
            armed = false
            let sign: CGFloat = offset < 0 ? -1 : 1
            withAnimation(DS.Motion.swipe) { offset = sign * width }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                close(animated: false)
                request(action)
            }
            return
        }
        let reveal = reveal(edge)
        // A flick opens, a flick back closes; otherwise past half the buttons stays open.
        let opens = offset < 0
            ? (velocity < -300 || (velocity < 300 && -offset > reveal / 2))
            : (velocity > 300 || (velocity > -300 && offset > reveal / 2))
        withAnimation(DS.Motion.swipe) {
            offset = opens && !edge.isEmpty ? (offset < 0 ? -reveal : reveal) : 0
        }
        if offset == 0, shared?.open == id { shared?.open = nil }
    }

    private func close(animated: Bool = true) {
        armed = false
        if animated {
            withAnimation(DS.Motion.swipe) { offset = 0 }
        } else {
            offset = 0
        }
        if shared?.open == id { shared?.open = nil }
    }
}

#endif
