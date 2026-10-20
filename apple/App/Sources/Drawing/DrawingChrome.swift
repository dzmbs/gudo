import DesignSystem
import DrawingKit
import Observation
import SwiftUI

/// What the draw overlay's toolbar shows.
@Observable
final class OverlayModel {
    var tool: DrawTool = .pen
    var agentName: String?
    var status: String?
    var busy = false
    var readOnly = false
    var isReopened = false
    /// Write (handwriting at the prompt) is offered (iPad).
    var canWrite = false
    /// The pane is narrow: tools fold into one menu.
    var compact = false
    @ObservationIgnored var onDone: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onSend: () -> Void = {}
    @ObservationIgnored var onRemove: () -> Void = {}
    @ObservationIgnored var onTool: (DrawTool) -> Void = { _ in }
    @ObservationIgnored var onWrite: () -> Void = {}
    @ObservationIgnored var onDebugRect: () -> Void = {}
}

/// The draw overlay's one toolbar: a quiet glass capsule at the bottom of the pane, never over
/// the first rows (Excalidraw's own tool island is hidden). Tools on the left; then Cancel, and
/// the primary action: Send to Claude/Codex when an agent runs in the pane or its tab (Done is
/// secondary then), else Done (⌘↩), which places the drawing in the terminal.
struct OverlayToolbar: View {
    @Bindable var model: OverlayModel

    var body: some View {
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
        .fixedSize()
        .accessibilityElement(children: .contain)
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
        .help(model.isReopened ? "Undo these edits and close" : "Discard the drawing")
        .accessibilityLabel("Cancel")
        .accessibilityIdentifier("drawing.cancel")
        if let agent = model.agentName {
            Button("Done") { model.onDone() }
                .buttonStyle(.glass)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Place the drawing in the terminal (⌘↩)")
                .accessibilityIdentifier("drawing.done")
            Button { model.onSend() } label: {
                Label(model.compact ? "Send" : "Send to \(agent)", systemImage: "paperplane.fill")
            }
            .buttonStyle(.primaryGlass)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .help("Place the drawing and attach it to \(agent)'s prompt (⇧⌘↩)")
            .accessibilityIdentifier("drawing.send")
        } else {
            Button("Done") { model.onDone() }
                .buttonStyle(.primaryGlass)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Place the drawing in the terminal (⌘↩)")
                .accessibilityIdentifier("drawing.done")
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
                .background(Circle().fill(selected ? Color.primary.opacity(0.14) : .clear))
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

/// After Done: says where the drawing went and offers the next step. Shown for a few seconds at
/// the bottom of the pane, where the toolbar was.
@Observable
final class PlacedNoticeModel {
    var agentName: String?
    var sending = false
    var sent = false
    @ObservationIgnored var onSend: () -> Void = {}
    @ObservationIgnored var onDismiss: () -> Void = {}
}

struct PlacedNotice: View {
    @Bindable var model: PlacedNoticeModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(model.sent ? "Sent to \(model.agentName ?? "the agent")" : "Placed in terminal")
                    .font(.callout.weight(.medium))
                if !model.sent {
                    Text("scrolls with the output")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let agent = model.agentName, !model.sent {
                    Text("·").foregroundStyle(.tertiary)
                    Button { model.onSend() } label: { Text("Send to \(agent)") }
                        .buttonStyle(.primaryGlass)
                        .disabled(model.sending)
                        .accessibilityIdentifier("drawing.notice.send")
                }
            }
            .padding(.leading, DS.Space.m)
            .padding(.trailing, model.agentName == nil || model.sent ? DS.Space.m : 6)
            .padding(.vertical, model.agentName == nil || model.sent ? DS.Space.s + 2 : 6)
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
