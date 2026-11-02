import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// On a phone-width window the tab shows its focused pane alone; its floating windows become
/// picture in picture: small live terminals resting in the corners, like a FaceTime call over
/// another app. Drag one to any corner (a flick carries it); tap to bring it full screen. The
/// pane keeps its grid (it is drawn smaller, never reflowed), and none sits on a fold.
struct PictureInPicture: View {
    let workspace: Workspace
    let tab: Tab
    @Environment(WindowModel.self) private var model

    /// The small window's size: wide enough to read an agent's last lines.
    static let size = CGSize(width: 176, height: 120)

    var body: some View {
        let windows = model.visibleWindows(in: workspace).filter { !$0.minimized && !$0.panes.contains(tab.focused) }
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let origin = geometry.frame(in: .global).origin
            let fold = model.fold.gutter.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            let corners = FloatGeometry.pipCorners(size: Self.size, in: bounds.insetBy(dx: 0, dy: 44), fold: fold)
            ZStack(alignment: .topLeading) {
                ForEach(Array(windows.prefix(max(corners.count, 1)).enumerated()), id: \.element.id) { index, window in
                    PictureInPictureWindow(
                        window: window, workspace: workspace, corners: corners,
                        home: Self.home(for: window, index: index, corners: corners, in: bounds))
                }
            }
        }
        .allowsHitTesting(!windows.isEmpty)
    }

    /// Where a window rests until moved: the corner nearest its frame on larger screens, else
    /// the next free one from the bottom right.
    private static func home(for window: FloatWindow, index: Int, corners: [CGRect], in bounds: CGRect) -> CGRect {
        guard !corners.isEmpty else { return CGRect(origin: .zero, size: size) }
        let centre = CGPoint(x: (window.frame.x + window.frame.width / 2) * bounds.width, y: (window.frame.y + window.frame.height / 2) * bounds.height)
        let byFrame = corners.sorted { hypot($0.midX - centre.x, $0.midY - centre.y) < hypot($1.midX - centre.x, $1.midY - centre.y) }
        return byFrame[index % byFrame.count]
    }
}

private struct PictureInPictureWindow: View {
    let window: FloatWindow
    let workspace: Workspace
    let corners: [CGRect]
    let home: CGRect
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @State private var rest: CGRect?
    @State private var drag = CGSize.zero
    @State private var taps = 0

    var body: some View {
        let pane = window.panes[0]
        let frame = rest ?? home
        let program = model.programIdentity(ofPane: pane, onGroup: workspace.groupId)
        let state = model.paneStatus.state(of: pane.description)
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                ProgramMark(program, size: 10)
                Text(program.isShell ? workspace.programName(of: pane) : program.displayName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let state, state != .idle { StatusIndicator(state, size: 8) }
            }
            .foregroundStyle(DS.Palette.text)
            .padding(.horizontal, DS.Space.s)
            .frame(height: 20)
            MiniTerminal(pane: pane, workspace: workspace)
        }
        .frame(width: PictureInPicture.size.width, height: PictureInPicture.size.height)
        .background(theme.background)
        .clipShape(.rect(cornerRadius: DS.Radius.searchPanel, style: .continuous))
        .glassEdge(RoundedRectangle(cornerRadius: DS.Radius.searchPanel, style: .continuous))
        .shadow(.panel)
        .contentShape(.rect(cornerRadius: DS.Radius.searchPanel))
        .offset(x: frame.minX + drag.width, y: frame.minY + drag.height)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    let centre = CGPoint(x: frame.midX + value.translation.width, y: frame.midY + value.translation.height)
                    let corner = FloatGeometry.pipCorner(
                        for: centre, velocity: CGVector(dx: value.velocity.width, dy: value.velocity.height), corners: corners)
                    withAnimation(DS.Motion.settle) {
                        rest = corner ?? frame
                        drag = .zero
                    }
                    taps += 1
                })
        .onTapGesture {
            taps += 1
            withAnimation(DS.Motion.lift) { workspace.apply(.focus(pane)) }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") { workspace.apply(.focus(pane)) }
            Button("Minimize Floating Window", systemImage: "minus.rectangle") { model.toggleMinimized(pane, in: workspace) }
            Button("Dock Pane", systemImage: "square.on.square") { model.dock(pane, in: workspace) }
            Divider()
            Button("Close Pane", systemImage: "xmark", role: .destructive) { workspace.apply(.close(pane)) }
        }
        .sensoryFeedback(DS.Haptic.select, trigger: taps)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(program.displayName), picture in picture")
        .accessibilityHint("Opens the floating pane")
        .accessibilityIdentifier("pip-window")
    }
}

/// A pane's live terminal at its own grid, drawn small: never resized, so the program and the
/// other devices keep their layout.
private struct MiniTerminal: View {
    let pane: PaneId
    let workspace: Workspace
    @Environment(\.terminalTheme) private var theme
    static let scale: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            if let terminal = workspace.panes[pane] {
                let cell = workspace.cellSize ?? CGSize(width: 8, height: 17)
                let grid = workspace.grids[pane] ?? GridSize(cols: 80, rows: 24)
                let padding = workspace.appearance.padding
                let natural = CGSize(width: CGFloat(grid.cols) * cell.width + 2 * padding, height: CGFloat(grid.rows) * cell.height + 2 * padding)
                // The latest lines, half size: where an agent's output is.
                TerminalHost(pane: terminal, isFocused: false, workspace: workspace)
                    .frame(width: natural.width, height: natural.height)
                    .scaleEffect(Self.scale, anchor: .bottomLeading)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            } else {
                theme.background
            }
        }
        .clipped()
    }
}
