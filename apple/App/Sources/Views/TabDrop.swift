import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// A tab of the same host dragged onto the pane merges into its tab on the nearest edge,
    /// with that half of the pane lit while it hovers (Ghostty's split drop zones).
    func tabDropTarget(pane: PaneId, workspace: Workspace, enabled: Bool) -> some View {
        modifier(TabDropTarget(pane: pane, workspace: workspace, enabled: enabled))
    }
}

private struct TabDropTarget: ViewModifier {
    let pane: PaneId
    let workspace: Workspace
    let enabled: Bool
    @Environment(WindowModel.self) private var model
    @State private var side: Direction?
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
                .overlay(alignment: side.map(Self.alignment) ?? .center) {
                    if let side {
                        RoundedRectangle(cornerRadius: DS.Radius.pane)
                            .fill(DS.Palette.accent.opacity(0.25))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.pane).strokeBorder(DS.Palette.accent.opacity(0.6), lineWidth: 1.5))
                            .frame(
                                width: side.axis == .horizontal ? size.width / 2 : nil,
                                height: side.axis == .vertical ? size.height / 2 : nil)
                            .padding(DS.Space.s)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("tab-drop-\(side.rawValue)")
                    }
                }
                .animation(DS.Motion.quick, value: side)
                .onDrop(of: [.text], delegate: Delegate(size: size, side: $side, source: source, merge: merge))
        } else {
            content
        }
    }

    /// The dragged tab, when it can merge here: same host, another tab.
    private func source() -> TabId? {
        guard let ref = model.draggedTab, ref.hostId == workspace.groupId,
              ref.tab != workspace.session.tab(containing: pane)?.id
        else { return nil }
        return ref.tab
    }

    private func merge(_ side: Direction) {
        guard let tab = source(), let target = workspace.session.tab(containing: pane) else { return }
        model.draggedTab = nil
        model.mergeTab(tab, in: workspace, into: target, beside: pane, side: side)
    }

    private static func alignment(_ side: Direction) -> Alignment {
        switch side {
        case .left: .leading
        case .right: .trailing
        case .up: .top
        case .down: .bottom
        }
    }

    private struct Delegate: DropDelegate {
        let size: CGSize
        @Binding var side: Direction?
        let source: () -> TabId?
        let merge: (Direction) -> Void

        func validateDrop(info: DropInfo) -> Bool { source() != nil }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard source() != nil else { return DropProposal(operation: .forbidden) }
            side = Self.edge(of: info.location, in: size)
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) { side = nil }

        func performDrop(info: DropInfo) -> Bool {
            side = nil
            guard source() != nil else { return false }
            merge(Self.edge(of: info.location, in: size))
            return true
        }

        /// The edge nearest the point, by the pane's diagonals (Ghostty's four triangles).
        static func edge(of point: CGPoint, in size: CGSize) -> Direction {
            let x = size.width > 0 ? point.x / size.width : 0.5
            let y = size.height > 0 ? point.y / size.height : 0.5
            let distances: [(Direction, CGFloat)] = [(.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)]
            return distances.min { $0.1 < $1.1 }!.0
        }
    }
}
