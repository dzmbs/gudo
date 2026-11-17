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
    /// The buttons' opacity on an unhovered header, the same on every pane so nothing changes
    /// when focus moves: hidden on the Mac (hover shows them), quiet on touch, where there is no
    /// hover.
    #if os(macOS)
    static let restingOpacity = 0.0
    #else
    static let restingOpacity = DS.Opacity.mutedGlyph
    #endif
    /// A status at the trailing edge sits as far in as the title does at the leading one (the
    /// band's own trailing inset is the buttons', which carry their own room).
    static let statusInset = DS.Space.s - DS.Space.xxs
    /// Headers come and go with a split by fading in the structural spring, over a grid
    /// already laid out below them.
    static let arrival = MotionTransition(role: .structural)
    #if os(iOS)
    static let height = DS.Size.touchTarget
    #else
    static let height: CGFloat = 24
    #endif

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
        let state = model.agentState(ofPane: id, onGroup: workspace.groupId)
        let program = model.programIdentity(ofPane: id, onGroup: workspace.groupId)
        let window = workspace.window(of: id)
        let accounts = program.isShell ? nil : model.accountBook(onGroup: workspace.groupId)
        let headline = PaneHeadline(identity: program, shellName: workspace.programName(of: id), directory: workspace.directory(ofPane: id))
        HStack(spacing: DS.Space.row) {
            ProgramTile(program, state: state)
            PaneTitle(headline: headline, isFocused: isFocused) {
                // "Claude Code · Work": only where the host has more than one account for it.
                if let label = accounts?.paneLabel(id.rawValue) {
                    PaneAccountLabel(name: label.name, color: label.color, emphasized: isFocused)
                }
            }
            if namesHost, let group = model.groups.group(workspace.groupId) {
                HostChip(group: group, emphasized: isFocused)
            }
            if let state, state != .idle {
                StatePill(state)
                    .layoutPriority(1)
                    .motionTransition(.pill(anchor: .leading))
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
            #if os(iOS)
            if let pane = workspace.panes[id], let chat = pane.chat, chat.agent != nil {
                PaneChatToggle(pane: pane, state: chat)
            }
            #endif
            // Before the status: hidden at rest on the Mac, they would leave it floating where
            // they stand.
            PaneHeaderButtons(id: id, workspace: workspace, window: window, focus: focus)
                .opacity(isHovered ? 1 : Self.restingOpacity)
                .animation(DS.Motion.micro, value: isHovered)
            if let hint = accounts?.limitHint(forPane: id.rawValue) {
                LimitHintMenu(hint: hint) {
                    model.startAgent(onGroup: workspace.groupId, agent: hint.alternative.agent, account: hint.alternative.id, from: id)
                }
                .padding(.trailing, Self.statusInset)
            }
            PanePresence(workspace: workspace, pane: id)
        }
        .paneHeaderBand(isFocused: isFocused)
        .onChange(of: PaneArrangement.HeaderStill(headline: headline, isFocused: isFocused), initial: true) { _, still in
            arrangement?.remember(still, of: id)
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
        withAnimation(DS.Motion.structural) { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) }
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

/// What a pane header names: the program, then the folder it runs in.
struct PaneHeadline: Equatable {
    let identity: ProgramIdentity
    /// Shells keep their own word ("zsh"); programs their display name.
    let program: String
    let directory: String?

    init(identity: ProgramIdentity, shellName: String, directory: String?) {
        self.identity = identity
        program = identity.isShell ? shellName : identity.displayName
        self.directory = directory.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// "zsh  ~/projects/unnamed": the program in the text colour and its folder quieter, the
/// folder giving way from its start; both recede on an unfocused pane, with nothing moving.
struct PaneTitle<Detail: View>: View {
    let headline: PaneHeadline
    let isFocused: Bool
    let detail: Detail

    init(headline: PaneHeadline, isFocused: Bool, @ViewBuilder detail: () -> Detail = { EmptyView() }) {
        self.headline = headline
        self.isFocused = isFocused
        self.detail = detail()
    }

    var body: some View {
        HStack(spacing: DS.Space.row) {
            Text(verbatim: headline.program)
                .font(.caption.weight(.medium))
                .foregroundStyle(isFocused ? DS.Palette.text : DS.Palette.textSecondary)
                .lineLimit(1)
                .layoutPriority(1)
            detail
            if let directory = headline.directory {
                PathText(directory)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityLabel(TabLeadingMark.spoken(directory))
            }
        }
        // One element for VoiceOver: "zsh, Home folder", not a tilde of its own.
        .accessibilityElement(children: .combine)
        .animation(DS.Motion.micro, value: isFocused)
    }
}

/// A closed pane's header on its way out, as it last showed.
struct PaneHeaderStill: View {
    let still: PaneArrangement.HeaderStill

    var body: some View {
        HStack(spacing: DS.Space.row) {
            ProgramTile(still.headline.identity)
            PaneTitle(headline: still.headline, isFocused: still.isFocused)
            Spacer(minLength: 0)
        }
        .paneHeaderBand(isFocused: still.isFocused)
        .terminalSurfaceChrome()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// The header's band: its height, insets, the terminal's background and the rule under it,
    /// which marks the focused pane in the accent's ring tint.
    func paneHeaderBand(isFocused: Bool) -> some View {
        modifier(PaneHeaderBand(isFocused: isFocused))
    }
}

private struct PaneHeaderBand: ViewModifier {
    let isFocused: Bool
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    func body(content: Content) -> some View {
        // Compact panes are flush: the focused one's rule is its mark. A comfortable pane is a
        // surface of its own and brightens its edge instead (`PaneFocusEdge`).
        let marked = isFocused && paneStyle == .compact
        content
            .padding(.leading, DS.Space.s)
            .padding(.trailing, DS.Space.xxs)
            // The fixed band does not change when switching presentation or when an agent starts.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .frame(height: PaneHeader.height)
            .background(theme.background, ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.splitDivider)
                    .overlay {
                        Rectangle()
                            .fill(DS.Palette.accentRing)
                            .opacity(marked ? 1 : 0)
                    }
                    .frame(height: 1)
                    .animation(DS.Motion.micro, value: marked)
            }
    }
}

/// The focused comfortable pane's edge, brighter than its neighbours'. Nothing dims.
struct PaneFocusEdge: View {
    let isFocused: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        RoundedRectangle.rounded(DS.Radius.pane)
            .strokeBorder(DS.Palette.border, lineWidth: DS.Size.hairline(scale: displayScale))
            .opacity(isFocused ? 1 : 0)
            .animation(DS.Motion.micro, value: isFocused)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PaneHeaderButtons: View {
    let id: PaneId
    let workspace: Workspace
    let window: FloatWindow?
    let focus: () -> Void
    @Environment(WindowModel.self) private var model

    var body: some View {
        // A narrow pane keeps only its menu, which holds every one of these too.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                buttons
                menu
            }
            menu
        }
    }

    /// At most four, the same on every pane: split right, split down, zoom and close; a
    /// floating window's own controls (dock, minimize) take the splits' place. The rest is in
    /// the menu.
    @ViewBuilder private var buttons: some View {
        let zoomed = workspace.session.tab(containing: id)?.zoomed == id
        Group {
            if let window {
                HeaderButton("Dock Pane", systemImage: "square.on.square", shortcut: WorkspaceAction.toggleFloat, lit: true) {
                    model.toggleFloat(id, in: workspace)
                }
                .accessibilityIdentifier("pane-float-button")
                HeaderButton(
                    window.minimized ? "Restore Floating Window" : "Minimize Floating Window", systemImage: "minus",
                    shortcut: WorkspaceAction.minimizeFloat
                ) {
                    model.toggleMinimized(id, in: workspace)
                }
                .accessibilityIdentifier("pane-minimize-button")
            } else {
                HeaderButton("Split Right", systemImage: "rectangle.split.2x1", shortcut: WorkspaceAction.splitRight) {
                    act { WorkspaceAction.splitRight.perform(on: workspace, window: model) }
                }
                HeaderButton("Split Down", systemImage: "rectangle.split.1x2", shortcut: WorkspaceAction.splitDown) {
                    act { WorkspaceAction.splitDown.perform(on: workspace, window: model) }
                }
            }
            HeaderButton(
                zoomed ? "Restore Pane" : "Zoom Pane",
                systemImage: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                shortcut: WorkspaceAction.toggleZoom, lit: zoomed
            ) {
                act { withAnimation(DS.Motion.structural) { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) } }
            }
            HeaderButton("Close Pane", systemImage: "xmark", shortcut: WorkspaceAction.closePane) {
                act { WorkspaceAction.closePane.perform(on: workspace, window: model) }
            }
        }
    }

    private var menu: some View {
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
        .help("Pane Menu: browser, float, move, find, share")
        .accessibilityLabel("Pane Menu")
    }

    private func act(_ action: () -> Void) {
        focus()
        action()
    }
}

/// One header glyph: a hover fill like Ghostty's search buttons, the accent while lit. A
/// disabled glyph says why in its tooltip.
private struct HeaderButton: View {
    let title: String
    let systemImage: String
    let shortcut: WorkspaceAction
    var lit = false
    var disabledReason: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String, systemImage: String, shortcut: WorkspaceAction, lit: Bool = false, disabledReason: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.lit = lit
        self.disabledReason = disabledReason
        self.action = action
    }

    var body: some View {
        let reason = isEnabled ? nil : disabledReason
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(HeaderButtonStyle(isLit: lit))
        .help(reason.map { "\(title): \($0)" } ?? "\(title) (\(shortcut.shortcut.symbols.joined()))")
        .accessibilityLabel(title)
        .accessibilityHint(reason ?? "")
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    let isLit: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let state = ControlState(isHovered: isHovered, isPressed: configuration.isPressed, isSelected: isLit, isEnabled: isEnabled, tint: .accent)
        let shape = RoundedRectangle.rounded(DS.Radius.field)
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(ink)
            .frame(width: 22, height: 20)
            .controlFill(state, in: shape)
            .contentShape(.rect)
            .onHover { isHovered = $0 }
    }

    private var ink: ChromeStyle {
        let rest = isLit ? DS.Palette.accent : DS.Palette.textSecondary
        return isEnabled ? rest : rest.disabled
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
            focusThen { withAnimation(DS.Motion.structural) { WorkspaceAction.toggleZoom.perform(on: workspace, window: model) } }
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
