import PaneLayout
import SwiftUI

/// Renders a split tree recursively: leaves are panes, splits are two subtrees around a
/// draggable divider.
struct SplitTreeView: View {
    let node: Node
    let workspace: Workspace
    /// Draw the focus ring and dim unfocused panes (only when more than one pane is visible).
    let showsFocus: Bool

    var body: some View {
        switch node {
        case .leaf(let id):
            PaneSlot(id: id, workspace: workspace, showsFocus: showsFocus)
        case .split(let axis, let ratio, let first, let second):
            SplitContainer(axis: axis, ratio: ratio, first: first, second: second, workspace: workspace)
        }
    }
}

private struct SplitContainer: View {
    let axis: Axis
    let ratio: Double
    let first: Node
    let second: Node
    let workspace: Workspace

    private static let dividerThickness: CGFloat = 1
    private static let dividerHitThickness: CGFloat = 12

    /// Drag translation already applied, so each change sends only the new delta.
    @State private var appliedTranslation: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let extent = axis == .horizontal ? geometry.size.width : geometry.size.height
            let firstLength = ((extent - Self.dividerThickness) * ratio).rounded()
            if axis == .horizontal {
                HStack(spacing: 0) {
                    SplitTreeView(node: first, workspace: workspace, showsFocus: true).frame(width: firstLength)
                    divider(extent: extent)
                    SplitTreeView(node: second, workspace: workspace, showsFocus: true)
                }
            } else {
                VStack(spacing: 0) {
                    SplitTreeView(node: first, workspace: workspace, showsFocus: true).frame(height: firstLength)
                    divider(extent: extent)
                    SplitTreeView(node: second, workspace: workspace, showsFocus: true)
                }
            }
        }
    }

    private func divider(extent: CGFloat) -> some View {
        let horizontal = axis == .horizontal
        return Rectangle()
            .fill(.separator)
            .frame(width: horizontal ? Self.dividerThickness : nil, height: horizontal ? nil : Self.dividerThickness)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? Self.dividerHitThickness : nil, height: horizontal ? nil : Self.dividerHitThickness)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    #endif
                    .gesture(drag(extent: extent))
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Split divider")
            .accessibilityValue("\(Int((ratio * 100).rounded())) percent")
    }

    /// Moves the divider by resizing the pane on its leading side towards it, which `resize`
    /// resolves to exactly this split.
    private func drag(extent: CGFloat) -> some Gesture {
        // Global space: the divider moves under the finger, so local translations would undercount.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let translation = axis == .horizontal ? value.translation.width : value.translation.height
                let delta = translation - (appliedTranslation ?? 0)
                appliedTranslation = translation
                let pane = first.trailingPane(along: axis)
                workspace.apply(.resize(pane, axis == .horizontal ? .right : .down, amount: delta / max(extent, 1)))
            }
            .onEnded { _ in appliedTranslation = nil }
    }
}

/// One pane in the tree: the terminal, or why it failed to start.
struct PaneSlot: View {
    let id: PaneId
    let workspace: Workspace
    let showsFocus: Bool

    var body: some View {
        let focused = workspace.focusedPane == id
        Group {
            if let pane = workspace.panes[id] {
                TerminalHost(pane: pane, isFocused: focused, workspace: workspace)
            } else if let failure = workspace.failures[id] {
                ContentUnavailableView("Pane Failed to Start", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                Color.terminalBackground
            }
        }
        .overlay {
            if showsFocus {
                // Ghostty's unfocused-split-opacity (0.7) and a 2 pt accent ring (04-mobile-ux C3).
                if focused {
                    Rectangle().strokeBorder(.tint, lineWidth: 2).allowsHitTesting(false)
                } else {
                    Color.black.opacity(0.3).allowsHitTesting(false)
                }
            }
        }
    }
}

private extension Node {
    /// The pane touching this subtree's trailing edge along `axis` (right edge for horizontal).
    func trailingPane(along axis: Axis) -> PaneId {
        switch self {
        case .leaf(let pane): pane
        case .split(let splitAxis, _, let first, let second):
            splitAxis == axis ? second.trailingPane(along: axis) : first.trailingPane(along: axis)
        }
    }
}

extension Color {
    /// Ghostty's default background (#282C34), shown before a pane's first frame.
    static let terminalBackground = Color(red: 0x28 / 255, green: 0x2C / 255, blue: 0x34 / 255)
}
