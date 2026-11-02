import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import TerminalRenderer

/// Floating windows (docs/APP-ARCHITECTURE.md §28): what the header buttons, menus, palette and
/// keys do. Every change is a layout op, so a daemon keeps it for every device; a host whose
/// helper predates floats says so instead of doing nothing.
extension Workspace {
    /// Whether this host keeps floating windows: always in a layout the app keeps itself, on a
    /// daemon that offers them.
    var canFloat: Bool {
        guard let daemon = host as? DaemonConnection else { return true }
        return daemon.layout.supportsFloats
    }

    /// The window holding `pane`, if it floats.
    func window(of pane: PaneId) -> FloatWindow? {
        session.window(containing: pane)
    }

    /// Whether `pane` can float: it floats already, or its tab keeps another tiled pane.
    func canToggleFloat(_ pane: PaneId) -> Bool {
        guard canFloat, let tab = session.tab(containing: pane) else { return false }
        if session.isFloating(pane) { return true }
        return (session.tiledRoot(of: tab)?.panes.count ?? 0) > 1
    }
}

extension WindowModel {
    /// The workspace and pane the floating actions act on: `pane` there, else the focused one.
    private func floatTarget(_ pane: PaneId?, _ workspace: Workspace?) -> (Workspace, PaneId)? {
        guard activeMixedTab == nil, let workspace = workspace ?? self.workspace,
              let pane = pane ?? workspace.focusedPane else { return nil }
        return (workspace, pane)
    }

    private func floatsUnsupported(_ workspace: Workspace) {
        toasts.show(Toast(
            "Update the helper on \(groupName(workspace.groupId)) to float panes",
            systemImage: "arrow.up.circle", style: .neutral))
    }

    /// One coordinated spring for a window lifting out or settling back: the panes around it
    /// reflow in the same motion, their grids held until it ends.
    private func lift(_ body: () -> Void) {
        TerminalSurfaceHold.hold(for: DS.Motion.liftDuration)
        withAnimation(DS.Motion.lift, body)
    }

    /// Float or dock (⌥⌘↩, the header's float button).
    func toggleFloat(_ pane: PaneId? = nil, in workspace: Workspace? = nil) {
        guard let (workspace, pane) = floatTarget(pane, workspace) else { return }
        guard workspace.canFloat else { return floatsUnsupported(workspace) }
        if workspace.session.isFloating(pane) {
            dock(pane, in: workspace)
        } else if workspace.canToggleFloat(pane) {
            lift { workspace.apply(.float(pane, frame: nil)) }
            workspace.apply(.focus(pane))
        } else {
            toasts.show(Toast("A tab keeps one pane in place: split it first", systemImage: "rectangle.split.2x1", style: .neutral))
        }
    }

    /// The window holding `pane` docks where it is, splits and all.
    func dock(_ pane: PaneId, in workspace: Workspace) {
        guard workspace.session.isFloating(pane) else { return }
        lift { workspace.apply(.dock(pane, beside: nil, side: .right)) }
    }

    /// The window holding `pane` goes to the tray, or comes back from it (⇧⌘M).
    func toggleMinimized(_ pane: PaneId? = nil, in workspace: Workspace? = nil) {
        guard let (workspace, pane) = floatTarget(pane, workspace), let window = workspace.window(of: pane) else { return }
        lift {
            if window.minimized {
                workspace.apply(.focus(pane))
            } else {
                workspace.apply(.setFloat(pane, frame: nil, minimized: true, pinned: nil))
            }
        }
    }

    /// Shown over every tab of its host, or only its own.
    func togglePinned(_ pane: PaneId, in workspace: Workspace) {
        guard let window = workspace.window(of: pane) else { return }
        workspace.apply(.setFloat(pane, frame: nil, minimized: nil, pinned: !window.pinned))
    }

    /// Hides every floating window for a look at the panes under them, or shows them again
    /// (⌥⌘F, Quake's drop-down in reverse). Per window; the host keeps them as they are.
    func toggleFloatsHidden() {
        lift { floatsHidden.toggle() }
    }

    /// The windows over the shown tab, front to back, pinned ones from other tabs included.
    func visibleWindows(in workspace: Workspace) -> [FloatWindow] {
        guard let tab = workspace.session.activeTab else { return [] }
        let own = Set(workspace.session.windows(in: tab.id).map(\.id))
        return workspace.session.floats.filter { own.contains($0.id) || $0.pinned }.reversed()
    }

    /// The next pane (⌘]) or the previous one (⌘[): the tiled panes in reading order, then
    /// each window's front to back; a window in the tray comes out when reached.
    func focusPane(offset: Int) {
        guard activeMixedTab == nil, let workspace, let tab = workspace.session.activeTab else { return }
        let tiled = workspace.session.tiledRoot(of: tab)?.panes ?? []
        let floating = floatsHidden ? [] : visibleWindows(in: workspace).flatMap(\.panes)
        let order = tiled + floating
        guard let index = order.firstIndex(of: tab.focused), order.count > 1 else { return }
        let next = order[(index + offset + order.count) % order.count]
        withAnimation(DS.Motion.snappy) { workspace.apply(.focus(next)) }
    }

    /// The front window behind the focused one comes forward with the keyboard (⌥⌘]).
    func cycleFloats() {
        guard let workspace else { return }
        let windows = visibleWindows(in: workspace)
        guard !windows.isEmpty else { return }
        if floatsHidden { floatsHidden = false }
        let focused = workspace.focusedPane.flatMap(workspace.window(of:))
        // Front to back: the one after the focused window, or the frontmost.
        let next = focused.flatMap { f in windows.firstIndex { $0.id == f.id } }.map { windows[($0 + 1) % windows.count] } ?? windows[0]
        withAnimation(DS.Motion.snappy) { workspace.apply(.focus(next.panes[0])) }
    }

    /// Splits the focused pane along its longer side (⌘↩): wide panes side by side, tall ones
    /// stacked, judged by the pane's size on screen.
    func splitBestFit() {
        guard let workspace, let pane = workspace.focusedPane else { return }
        let size = paneSize(pane, in: workspace)
        let action: WorkspaceAction = size.width >= size.height ? .splitRight : .splitDown
        action.perform(on: workspace, window: self)
    }

    /// A pane's size on screen, from its tab's tree (or its window's frame) in the tab's area.
    func paneSize(_ pane: PaneId, in workspace: Workspace) -> CGSize {
        let area = CGRect(origin: .zero, size: terminalArea == .zero ? CGSize(width: 1200, height: 800) : terminalArea)
        let session = workspace.session
        guard let tab = session.tab(containing: pane) else { return area.size }
        if let window = session.window(containing: pane), let root = session.root(of: window) {
            return root.frames(in: FloatGeometry.rect(of: window.frame, in: area))[pane]?.size ?? area.size
        }
        return session.tiledRoot(of: tab)?.frames(in: area)[pane]?.size ?? area.size
    }

    /// ⌥⇧⌘ with an arrow: a tiled pane trades places past its neighbour that way; a floating
    /// window steps a twelfth of the tab, snapping where it lands.
    func movePane(_ direction: Direction) {
        guard let (workspace, pane) = floatTarget(nil, nil) else { return }
        if let window = workspace.window(of: pane) {
            var frame = window.frame
            let step = 1.0 / 12
            switch direction {
            case .left: frame.x -= step
            case .right: frame.x += step
            case .up: frame.y -= step
            case .down: frame.y += step
            }
            withAnimation(DS.Motion.settle) { workspace.apply(.setFloat(pane, frame: frame.clamped, minimized: nil, pinned: nil)) }
            return
        }
        guard workspace.canMovePanes, let tab = workspace.session.activeTab,
              let tiled = workspace.session.tiledRoot(of: tab)
        else { return }
        // The neighbour the focus would move to: the pane goes past it.
        var probe = Session(tabs: [Tab(id: tab.id, root: tiled, focused: pane)], activeTabId: tab.id)
        probe.apply(.focusDirection(direction))
        guard let neighbour = probe.activeTab?.focused, neighbour != pane else { return }
        withAnimation(DS.Motion.lift) { workspace.apply(.movePane(pane, beside: neighbour, side: direction)) }
    }

    /// ⌃⌘ with an arrow on a floating window grows it that way (shrinks with left/up), like
    /// moving the divider on a tiled pane.
    func resizeFloat(_ direction: Direction) -> Bool {
        guard let (workspace, pane) = floatTarget(nil, nil), let window = workspace.window(of: pane) else { return false }
        var frame = window.frame
        let step = 1.0 / 24
        switch direction {
        case .left: frame.width -= step
        case .right: frame.width += step
        case .up: frame.height -= step
        case .down: frame.height += step
        }
        withAnimation(DS.Motion.settle) { workspace.apply(.setFloat(pane, frame: frame.clamped, minimized: nil, pinned: nil)) }
        return true
    }

    /// The pane alone in a window of its own (Mac windows, iPad scenes): it moves to a new tab,
    /// which opens in the new window, and this window stays on the tab it showed.
    func popOut(_ pane: PaneId, in workspace: Workspace) {
        guard workspace.canMovePanes else { return }
        let before = currentTab
        let tabs = Set(workspace.session.tabs.map(\.id))
        if workspace.canMoveToNewTab(pane) {
            workspace.apply(.movePaneToNewTab(pane))
        }
        Task { @MainActor [weak self] in
            // The host answers with the new tab: open it there, then come back here.
            for _ in 0..<50 {
                if let tab = workspace.session.tab(containing: pane), !tabs.contains(tab.id) || workspace.session.tabs.count == 1 {
                    self?.openInNewWindow(TabRef(hostId: workspace.groupId, tab: tab.id))
                    if let before { self?.focus(before) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The pane's id as the terminal tools and `gudo` name it (`p12`).
    func copyPaneId(_ pane: PaneId) {
        PaneIdPasteboard.copy("p\(pane.rawValue)")
        toasts.show(Toast("Copied p\(pane.rawValue)", systemImage: "doc.on.doc", style: .neutral))
    }

    /// Clears the pane's terminal state on this device (modes, colours, screen) and asks the
    /// program to draw itself again.
    func resetTerminal(_ pane: PaneId, in workspace: Workspace) {
        guard let terminal = workspace.panes[pane] else { return }
        terminal.view.surface.terminal.write(Array("\u{1b}c".utf8))
        [UInt8(0x0c)].withUnsafeBytes { terminal.backend.write($0) }
    }

    /// Whether the floating actions apply to the focused pane (menus enable them by this).
    var focusedFloats: Bool {
        guard let workspace, let pane = workspace.focusedPane else { return false }
        return workspace.session.isFloating(pane)
    }
}

/// The holds `TerminalSurface` keeps while a layout animates, by duration in seconds.
enum TerminalSurfaceHold {
    static func hold(for seconds: Double) {
        TerminalSurface.holdGrids(for: .milliseconds(Int(seconds * 1000)))
    }
}

private enum PaneIdPasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
