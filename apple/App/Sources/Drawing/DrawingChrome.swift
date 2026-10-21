import DesignSystem
import DrawingKit
import Observation
import SwiftUI

/// What the draw overlay's toolbar shows.
@Observable
final class OverlayModel {
    var tool: DrawTool = .pen
    var status: String?
    var busy = false
    var readOnly = false
    var isReopened = false
    /// Write (handwriting at the prompt) is offered (iPad).
    var canWrite = false
    /// The pane is narrow: tools fold into one menu.
    var compact = false
    /// Agent panes the drawing can go to, on every host the window shows.
    var destinations: [AgentDestination] = []
    /// The agent in this pane or its tab: the primary button sends there.
    var primary: AgentDestination?
    /// Claude Code / Codex can be started with the drawing.
    var canStart = false
    /// The one-line "what is this for" hint (until the first drawing is finished).
    var showsHint = false
    /// The editor holds the scene (VoiceOver and UI tests read it as the toolbar's value).
    var loaded = false
    @ObservationIgnored var onAction: (DrawingAction) -> Void = { _ in }
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onRemove: () -> Void = {}
    @ObservationIgnored var onTool: (DrawTool) -> Void = { _ in }
    @ObservationIgnored var onWrite: () -> Void = {}
    @ObservationIgnored var onDebugRect: () -> Void = {}

    var menu: DrawingMenu {
        DrawingMenu.make(destinations: destinations, primary: primary, canStart: canStart, includeKeep: primary == nil, placement: false)
    }

    var hint: String {
        if let primary { return "Sketch over the output, then send it to \(primary.agent.title): it lands in the prompt as an image." }
        return "Sketch over the output, then send it to an agent as an image, copy or share it, or keep it here."
    }

    /// The hint shows until a first drawing is finished (sent, kept, copied, shared).
    static var hintSeen: Bool {
        get { UserDefaults.standard.bool(forKey: "drawingHintSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "drawingHintSeen") }
    }
}

/// The draw overlay's one toolbar: a quiet glass capsule at the bottom of the pane, never over
/// the first rows (Excalidraw's own tool island is hidden). Tools on the left; then Cancel (esc),
/// Keep (⌘↩: the drawing stays in the terminal output) and the primary action, which names where
/// the drawing goes: Send to Claude Code / Codex when an agent runs in the pane or its tab (⇧⌘↩,
/// with a menu of every other destination), else a Send To… menu (agents on any host in the
/// window, Start Claude Code / Codex with it, Copy Image, Share / Save, Keep in Terminal).
struct OverlayToolbar: View {
    @Bindable var model: OverlayModel

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if model.showsHint, !model.readOnly {
                Text(model.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, 6)
                    .floatingCapsule()
                    .transition(.opacity)
                    .accessibilityIdentifier("drawing.hint")
            }
            GlassEffectContainer {
                HStack(spacing: DS.Space.s) {
                    if let status = model.status {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 280)
                            .padding(.leading, 6)
                            .accessibilityIdentifier("drawing.status")
                    }
                    if model.readOnly {
                        Label("View Only", systemImage: "eye")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                        Button("Close") { model.onCancel() }
                            .buttonStyle(.glass)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("drawing.cancel")
                    } else {
                        tools
                        actions
                    }
                }
                .disabled(model.busy)
                .padding(6)
                .floatingCapsule()
            }
        }
        .animation(DS.Motion.overlay, value: model.showsHint)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityValue(model.loaded ? "ready" : "loading")
        .accessibilityIdentifier("drawing.toolbar")
    }

    @ViewBuilder private var tools: some View {
        if model.compact {
            Menu {
                Picker("Tool", selection: Binding(get: { model.tool }, set: { model.onTool($0) })) {
                    ForEach(DrawTool.allCases, id: \.self) { tool in
                        Label(tool.title, systemImage: tool.systemImage).tag(tool)
                    }
                }
                if model.canWrite {
                    Button { model.onWrite() } label: { Label("Write at Prompt", systemImage: "pencil.and.scribble") }
                }
            } label: {
                Image(systemName: model.tool.systemImage)
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .accessibilityLabel("Tool: \(model.tool.title)")
            .accessibilityIdentifier("drawing.tool")
        } else {
            HStack(spacing: 2) {
                ForEach(DrawTool.allCases, id: \.self) { tool in
                    ToolButton(tool: tool, selected: model.tool == tool) { model.onTool(tool) }
                }
                if model.canWrite {
                    Divider().frame(height: 20).padding(.horizontal, 4)
                    Button { model.onWrite() } label: {
                        Image(systemName: "pencil.and.scribble")
                            .frame(width: 32, height: 32)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Write at the prompt with Apple Pencil")
                    .accessibilityLabel("Write at Prompt")
                    .accessibilityIdentifier("drawing.write")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var actions: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "drawingDebug") {
            Button("Rect") { model.onDebugRect() }
                .buttonStyle(.glass)
                .accessibilityIdentifier("drawing.debugRect")
        }
        #endif
        if model.isReopened {
            Button(role: .destructive) { model.onRemove() } label: { Image(systemName: "trash") }
                .buttonStyle(.glass)
                .help("Remove the drawing from the terminal")
                .accessibilityLabel("Remove Drawing")
                .accessibilityIdentifier("drawing.remove")
        }
        Button { model.onCancel() } label: {
            if model.compact { Image(systemName: "xmark") } else { Text("Cancel") }
        }
        .buttonStyle(.glass)
        .keyboardShortcut(.cancelAction)
        .help(model.isReopened ? "Undo these edits and close (esc)" : "Discard the drawing (esc)")
        .accessibilityLabel("Cancel")
        .accessibilityIdentifier("drawing.cancel")
        Button { model.onAction(.keep) } label: {
            if model.compact { Image(systemName: "pin") } else { Text("Keep") }
        }
        .buttonStyle(.glass)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Keep the drawing in the terminal output; tap it later to send, copy or edit it (⌘↩)")
        .accessibilityLabel("Keep in Terminal")
        .accessibilityIdentifier("drawing.done")
        if let primary = model.primary {
            HStack(spacing: 2) {
                Button { model.onAction(.send(primary)) } label: {
                    Label(model.compact ? "Send" : "Send to \(primary.agent.title)", systemImage: "paperplane.fill")
                }
                .buttonStyle(.primaryGlass)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Attach the drawing to \(primary.agent.title)'s prompt as an image (⇧⌘↩)")
                .accessibilityIdentifier("drawing.send")
                Menu { DrawingMenuContent(menu: model.menu, perform: model.onAction) } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .frame(height: 20)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .menuIndicator(.hidden)
                .help("Send it somewhere else, copy or share it")
                .accessibilityLabel("More Destinations")
                .accessibilityIdentifier("drawing.more")
            }
        } else {
            Menu { DrawingMenuContent(menu: model.menu, perform: model.onAction) } label: {
                Label(model.compact ? "Send" : "Send To…", systemImage: "paperplane.fill")
            }
            .menuStyle(.button)
            .buttonStyle(.primaryGlass)
            .menuIndicator(.hidden)
            .help("Send the drawing to an agent, copy or share it")
            .accessibilityLabel("Send To")
            .accessibilityIdentifier("drawing.send")
        }
    }
}

/// A `DrawingMenu` as SwiftUI menu content.
struct DrawingMenuContent: View {
    let menu: DrawingMenu
    let perform: (DrawingAction) -> Void

    var body: some View {
        ForEach(menu.sections) { section in
            if section.submenu, let title = section.title {
                Menu { items(section) } label: { Label(title, systemImage: section.systemImage ?? "ellipsis") }
                    .accessibilityIdentifier("drawing.menu.\(title.lowercased())")
            } else if let title = section.title {
                Section(title) { items(section) }
            } else {
                Section { items(section) }
            }
        }
    }

    private func items(_ section: DrawingMenu.Section) -> some View {
        ForEach(section.items) { item in
            if let action = item.action {
                Button(role: item.destructive ? .destructive : nil) { perform(action) } label: {
                    Label {
                        Text(item.title)
                        if let subtitle = item.subtitle { Text(subtitle) }
                    } icon: {
                        Image(systemName: item.systemImage)
                    }
                }
                .accessibilityIdentifier("drawing.menu.\(item.id)")
            }
        }
    }
}

/// One tool in the strip: an SF Symbol, the selected one on a quiet fill (no tint: colour is for
/// state, DESIGN.md).
private struct ToolButton: View {
    let tool: DrawTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DS.Palette.pressedFill.opacity(selected ? 1 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .help("\(tool.title) (\(String(tool.key).uppercased()))")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("drawing.tool.\(tool.rawValue)")
    }
}

/// After a drawing is finished: says where it went and what it is for now (it stays in the
/// output; tap it to send, copy or edit), with Send to Claude/Codex when it was only kept and an
/// agent runs nearby. Shown for a few seconds at the bottom of the pane, where the toolbar was.
@Observable
final class PlacedNoticeModel {
    enum Phase: Equatable {
        case working(String)
        case done(PlacedOutcome)
        case failed(String)
    }

    var phase = Phase.done(.kept)
    /// The agent the notice offers to send to (only after Keep).
    var agentName: String?
    @ObservationIgnored var onSend: () -> Void = {}
    @ObservationIgnored var onDismiss: () -> Void = {}

    var title: String {
        switch phase {
        case .working(let text): text
        case .failed(let text): text
        case .done(.kept), .done(.shared): "Kept in terminal"
        case .done(.sent(let name)): "Sent to \(name)"
        case .done(.copied): "Image copied"
        case .done(.copiedText): "Text copied"
        case .done(.saved(let name)): "Saved \u{201C}\(name)\u{201D}"
        }
    }

    var detail: String? {
        switch phase {
        case .working, .failed: nil
        case .done(.kept), .done(.shared): "tap it to send, copy or edit"
        case .done(.sent): "in the prompt as an image · also kept here"
        case .done(.copied), .done(.copiedText), .done(.saved): "also kept in the terminal"
        }
    }

    var symbol: String {
        switch phase {
        case .working: "hourglass"
        case .failed: "exclamationmark.triangle.fill"
        case .done(.sent): "paperplane.fill"
        case .done(.copied): "doc.on.doc"
        case .done(.copiedText): "text.quote"
        case .done(.saved): "square.and.arrow.down"
        case .done: "pin.fill"
        }
    }

    var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    var offersSend: Bool { agentName != nil && phase == .done(.kept) }
}

struct PlacedNotice: View {
    @Bindable var model: PlacedNoticeModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: DS.Space.s) {
                if case .working = model.phase {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.symbol)
                        .foregroundStyle(model.isFailure ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
                Text(model.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let detail = model.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if model.offersSend, let agent = model.agentName {
                    Text("·").foregroundStyle(.tertiary)
                    Button { model.onSend() } label: { Text("Send to \(agent)") }
                        .buttonStyle(.primaryGlass)
                        .accessibilityIdentifier("drawing.notice.send")
                }
            }
            .padding(.leading, DS.Space.m)
            .padding(.trailing, model.offersSend ? 6 : DS.Space.m)
            .padding(.vertical, model.offersSend ? 6 : DS.Space.gap10)
            .floatingCapsule(interactive: true)
        }
        .fixedSize()
        .onTapGesture { model.onDismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("drawing.notice")
    }
}

/// Drawings whose row is gone (cleared, evicted from the scrollback ring, a daemon restart):
/// never dropped silently, they wait here to be placed again at the cursor or removed.
@Observable
final class LooseTrayModel {
    struct Item: Identifiable, Equatable {
        let id: UInt64
        var title: String
    }

    var items: [Item] = []
    var agentName: String?
    @ObservationIgnored var onPlace: (UInt64) -> Void = { _ in }
    @ObservationIgnored var onSend: (UInt64) -> Void = { _ in }
    @ObservationIgnored var onRemove: (UInt64) -> Void = { _ in }
}

struct LooseTray: View {
    @Bindable var model: LooseTrayModel

    var body: some View {
        Menu {
            Section("Their rows left the scrollback") {
                ForEach(model.items) { item in
                    Menu(item.title) {
                        Button { model.onPlace(item.id) } label: { Label("Place at Cursor", systemImage: "pin") }
                        if let agent = model.agentName {
                            Button { model.onSend(item.id) } label: { Label("Send to \(agent)", systemImage: "paperplane") }
                        }
                        Button(role: .destructive) { model.onRemove(item.id) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pin.slash")
                Text("\(model.items.count)").monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 5)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .floatingCapsule(interactive: true)
        .fixedSize()
        .help("Drawings whose rows left the scrollback")
        .accessibilityLabel(model.items.count == 1 ? "1 loose drawing" : "\(model.items.count) loose drawings")
        .accessibilityIdentifier("drawing.looseTray")
    }
}
