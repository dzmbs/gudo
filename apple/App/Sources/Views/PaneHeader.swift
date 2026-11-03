import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// A pane's title strip: program mark and name, status, then the pane's buttons. It sits on the
/// terminal background so the pane still reads as one surface.
///
/// It is also the pane's handle: drag it to rearrange (a tiled pane, or one of several in a
/// window) or to move its window (a window of one pane); double-click to zoom; right-click or
/// long-press for the context menu.
struct PaneHeader: View {
    /// The buttons' opacity on an unfocused, unhovered header: hidden on the Mac (hover shows
    /// them), quiet on touch, where there is no hover.
    #if os(macOS)
    static let restingOpacity = 0.0
    #else
    static let restingOpacity = DS.Opacity.mutedGlyph
    #endif
    static let height: CGFloat = 24

    let id: PaneId
    let workspace: Workspace
    let isFocused: Bool
    /// A mixed tab: name the pane's host after its program.
    var namesHost = false
    let focus: () -> Void

    @Environment(\.terminalTheme) private var theme
    @Environment(WindowModel.self) private var model
    @Environment(PaneArrangement.self) private var arrangement: PaneArrangement?
    @State private var isHovered = false
    @GestureState private var isDragging = false

    var body: some View {
        let state = model.paneStatus.state(of: id.description)
        let program = model.programIdentity(ofPane: id, onGroup: workspace.groupId)
        let window = workspace.window(of: id)
        let accounts = program.isShell ? nil : model.accountBook(onGroup: workspace.groupId)
        HStack(spacing: DS.Space.row) {
            ProgramMark(program, size: 12)
                .foregroundStyle(isFocused ? DS.Palette.text : DS.Palette.textSecondary)
            // Shells keep their own word ("zsh", "canvas"); programs their display name.
            Text(program.isShell ? workspace.programName(of: id) : program.displayName)
                .font(.caption.weight(isFocused ? .semibold : .regular))
                .foregroundStyle(isFocused ? DS.Palette.text : DS.Palette.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            // "Claude Code · Work": only where the host has more than one account for it.
            if let label = accounts?.paneLabel(id.rawValue) {
                PaneAccountLabel(name: label.name, color: label.color, emphasized: isFocused)
            }
            if window != nil, let cwd = workspace.panes[id]?.workingDirectory, !cwd.isEmpty {
                Text(verbatim: (cwd as NSString).abbreviatingWithTildeInPath)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if namesHost, let group = model.groups.group(workspace.groupId) {
                HostChip(group: group, emphasized: isFocused)
            }
            if let state, state != .idle {
                StatusIndicator(state, size: 10)
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(state.color)
                    .layoutPriority(1)
                // The program's own words ("Which framework? · 40%"): they take the squeeze.
                if let detail = model.paneStatus.detail(of: id.description) {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(detail)
                }
            }
            Spacer(minLength: 0)
            if let hint = accounts?.limitHint(forPane: id.rawValue) {
                LimitHintMenu(hint: hint) {
                    model.startAgent(onGroup: workspace.groupId, agent: hint.alternative.agent, account: hint.alternative.id, from: id)
                }
            }
            PanePresence(workspace: workspace, pane: id)
            PaneHeaderButtons(id: id, workspace: workspace, window: window, focus: focus)
                .opacity(isFocused || isHovered ? 1 : Self.restingOpacity)
        }
        .padding(.leading, DS.Space.s)
        .padding(.trailing, DS.Space.xxs)
        // A fixed 24 pt band over the grid: its caption text grows only so far.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .frame(height: Self.height)
        .background(theme.background, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.splitDivider).frame(height: 1)
        }
        .contentShape(.rect)
        .onTapGesture { focus() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { zoom() })
        .gesture(handleDrag, including: arrangement?.workspace === workspace ? .all : .subviews)
        // A drag the system cancels never ends: the preview goes and the panes settle back.
        .onChange(of: isDragging) { _, dragging in
            guard !dragging, let arrangement else { return }
            // After `onEnded`, which drops it when the drag did end.
            Task { if arrangement.paneDrag?.pane == id { arrangement.cancelDrag() } }
        }
        .onHover { isHovered = $0 }
        .task(id: workspace.groupId) { model.loadAccounts(onGroup: workspace.groupId) }
        .contextMenu {
            PaneContextItems(workspace: workspace, model: model, pane: id, focusPane: focus)
        }
        .accessibilityAction(named: "Zoom") { zoom() }
    }

    private func zoom() {
        focus()
        withAnimation(DS.Motion.split) { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) }
    }

    /// Moves the pane's window when it is the window's only pane; otherwise drags the pane to
    /// a new place, with the region it would take lit under the hand.
    private var handleDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(PaneArrangement.space))
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard let arrangement else { return }
                if let window = workspace.window(of: id), window.panes.count == 1 {
                    arrangement.move(window.id, by: value.translation, at: value.location)
                } else {
                    arrangement.drag(id, to: value.location)
                }
            }
            .onEnded { value in
                guard let arrangement else { return }
                if let window = workspace.window(of: id), window.panes.count == 1, arrangement.paneDrag == nil {
                    arrangement.endMove(window.id, by: value.translation, velocity: value.velocity)
                } else {
                    arrangement.endDrag(id, at: value.location)
                }
            }
    }
}

private struct PaneHeaderButtons: View {
    let id: PaneId
    let workspace: Workspace
    let window: FloatWindow?
    let focus: () -> Void
    @Environment(WindowModel.self) private var model

    var body: some View {
        let zoomed = workspace.session.tab(containing: id)?.zoomed == id
        HStack(spacing: 0) {
            HeaderButton("Split Right", systemImage: "rectangle.split.2x1", shortcut: WorkspaceAction.splitRight) {
                act { WorkspaceAction.splitRight.perform(on: workspace, window: model) }
            }
            HeaderButton("Split Down", systemImage: "rectangle.split.1x2", shortcut: WorkspaceAction.splitDown) {
                act { WorkspaceAction.splitDown.perform(on: workspace, window: model) }
            }
            HeaderButton(WorkspaceAction.openBrowser.title, systemImage: "globe", shortcut: WorkspaceAction.openBrowser) {
                act { model.openBrowser(besidePane: id, onGroup: workspace.groupId) }
            }
            .accessibilityIdentifier("pane-browser-button")
            if model.activeMixedTab == nil {
                HeaderButton(
                    window == nil ? "Float Pane" : "Dock Pane", systemImage: "square.on.square",
                    shortcut: WorkspaceAction.toggleFloat, lit: window != nil
                ) {
                    model.toggleFloat(id, in: workspace)
                }
                .disabled(window == nil && !workspace.canToggleFloat(id) && workspace.canFloat)
                .accessibilityIdentifier("pane-float-button")
            }
            if window != nil {
                HeaderButton("Minimize Floating Window", systemImage: "minus", shortcut: WorkspaceAction.minimizeFloat) {
                    model.toggleMinimized(id, in: workspace)
                }
                .accessibilityIdentifier("pane-minimize-button")
                // Shows once the header has made room for it.
                .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.12).delay(0.2)), removal: .opacity.animation(.easeOut(duration: 0.08))))
            }
            HeaderButton(
                zoomed ? "Restore Pane" : "Zoom Pane",
                systemImage: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                shortcut: WorkspaceAction.toggleZoom, lit: zoomed
            ) {
                act { withAnimation(DS.Motion.split) { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) } }
            }
            HeaderButton("Close Pane", systemImage: "xmark", shortcut: WorkspaceAction.closePane) {
                act { WorkspaceAction.closePane.perform(on: workspace, window: model) }
            }
            Menu {
                PaneMenuItems(workspace: workspace, model: model, pane: id, focusPane: focus)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: 22, height: 20)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pane Menu: split, zoom, find, share, close")
            .accessibilityLabel("Pane Menu")
        }
    }

    private func act(_ action: () -> Void) {
        focus()
        action()
    }
}

/// One header glyph: a hover fill like Ghostty's search buttons, the accent while lit.
private struct HeaderButton: View {
    let title: String
    let systemImage: String
    let shortcut: WorkspaceAction
    var lit = false
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String, shortcut: WorkspaceAction, lit: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.lit = lit
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(lit ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.textSecondary))
                .frame(width: 22, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(lit ? AnyShapeStyle(DS.Palette.accent.opacity(0.14)) : (hovered ? AnyShapeStyle(DS.Palette.hoverFill) : AnyShapeStyle(Color.clear)))
                }
                .contentShape(.rect)
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(title) (\(shortcut.shortcut.symbols.joined()))")
        .accessibilityLabel(title)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
    }
}

/// The pane header's context menu.
struct PaneContextItems: View {
    let workspace: Workspace
    let model: WindowModel
    let pane: PaneId
    let focusPane: () -> Void

    var body: some View {
        Button("Reset Terminal", systemImage: "arrow.counterclockwise") { model.resetTerminal(pane, in: workspace) }
        Divider()
        Button("Split Right", systemImage: "rectangle.split.2x1") { focusThen { WorkspaceAction.splitRight.perform(on: workspace, window: model) } }
        Button("Split Down", systemImage: "rectangle.split.1x2") { focusThen { WorkspaceAction.splitDown.perform(on: workspace, window: model) } }
        Divider()
        if model.activeMixedTab == nil {
            FloatMenuItems(workspace: workspace, model: model, pane: pane)
        }
        Button("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right") {
            focusThen { withAnimation(DS.Motion.split) { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) } }
        }
        if WindowSupport.multipleWindows, model.activeMixedTab == nil {
            Button("Pop Out to Window", systemImage: "macwindow.badge.plus") { model.popOut(pane, in: workspace) }
                .disabled(!workspace.canMovePanes)
        }
        Button("Copy Pane ID", systemImage: "number") { model.copyPaneId(pane) }
        Divider()
        Button("Close Pane", systemImage: "xmark", role: .destructive) {
            focusThen { WorkspaceAction.closePane.perform(on: workspace, window: model) }
        }
    }

    private func focusThen(_ action: () -> Void) {
        focusPane()
        action()
    }
}

/// Float or Dock, Minimize, Pin Across Tabs: in the pane menu and the header's context menu.
struct FloatMenuItems: View {
    let workspace: Workspace
    let model: WindowModel
    let pane: PaneId

    var body: some View {
        let window = workspace.window(of: pane)
        Button(window == nil ? "Float Pane" : "Dock Pane", systemImage: "square.on.square") {
            model.toggleFloat(pane, in: workspace)
        }
        .disabled(window == nil && workspace.canFloat && !workspace.canToggleFloat(pane))
        if let window {
            Button(window.minimized ? "Restore Floating Window" : "Minimize Floating Window", systemImage: "minus.rectangle") {
                model.toggleMinimized(pane, in: workspace)
            }
            Toggle(isOn: Binding(get: { window.pinned }, set: { _ in model.togglePinned(pane, in: workspace) })) {
                Label("Pin Across Tabs", systemImage: "pin")
            }
        }
    }
}

/// Whether this device opens windows of its own (Mac windows, iPad scenes).
enum WindowSupport {
    @MainActor static var multipleWindows: Bool {
        #if os(macOS)
        true
        #else
        UIApplication.shared.supportsMultipleScenes && UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
}

/// The account an agent pane runs under, after its name: "· ● Work".
struct PaneAccountLabel: View {
    let name: String
    let color: UInt8
    var emphasized = false

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            Text(verbatim: "·")
                .foregroundStyle(DS.Palette.textTertiary)
            AccountDot(color: color, size: 6)
            Text(name)
                .foregroundStyle(emphasized ? DS.Palette.text : DS.Palette.textSecondary)
                .lineLimit(1)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Account: \(name)")
        .help("Runs under the \(name) account")
    }
}

/// A pane's account is at a plan limit: a quiet mark whose menu offers a new tab under another
/// signed-in account. Nothing switches by itself.
struct LimitHintMenu: View {
    let hint: LimitHint
    let start: () -> Void

    var body: some View {
        Menu {
            Text(hint.message())
            Button(hint.action, systemImage: "plus.rectangle.on.rectangle", action: start)
        } label: {
            Label("At Limit", systemImage: "gauge.with.dots.needle.100percent")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(DS.Palette.attention)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(hint.message())
        .accessibilityIdentifier("pane-limit-hint")
    }
}
