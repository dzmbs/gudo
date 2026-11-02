import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import TerminalRenderer

/// Floating window actions. Every change is a layout op, so a daemon keeps it for every device.
extension Workspace {
    /// Always in a layout the app keeps itself; on a daemon only if it offers them.
    var canFloat: Bool {
        guard let daemon = host as? DaemonConnection else { return true }
        return daemon.layout.supportsFloats
    }

    func window(of pane: PaneId) -> FloatWindow? {
        session.window(containing: pane)
    }

    /// A tab must keep at least one tiled pane.
    func canToggleFloat(_ pane: PaneId) -> Bool {
        guard canFloat, let tab = session.tab(containing: pane) else { return false }
        if session.isFloating(pane) { return true }
        return (session.tiledRoot(of: tab)?.panes.count ?? 0) > 1
    }
}

extension WindowModel {
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

    /// The panes around reflow in the same spring, their grids held until it ends.
    private func lift(_ body: () -> Void) {
        TerminalSurfaceHold.hold(for: DS.Motion.liftDuration)
        withAnimation(DS.Motion.lift, body)
    }

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

    /// Docks the whole window holding `pane`, splits and all.
    func dock(_ pane: PaneId, in workspace: Workspace) {
        guard workspace.session.isFloating(pane) else { return }
        lift { workspace.apply(.dock(pane, beside: nil, side: .right)) }
    }

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

    /// Pinned windows show over every tab of their host.
    func togglePinned(_ pane: PaneId, in workspace: Workspace) {
        guard let window = workspace.window(of: pane) else { return }
        workspace.apply(.setFloat(pane, frame: nil, minimized: nil, pinned: !window.pinned))
    }

    /// Per window; the host keeps the floats as they are.
    func toggleFloatsHidden() {
        lift { floatsHidden.toggle() }
    }

    /// Front to back, pinned ones from other tabs included.
    func visibleWindows(in workspace: Workspace) -> [FloatWindow] {
        guard let tab = workspace.session.activeTab else { return [] }
        let tabWindows = Set(workspace.session.windows(in: tab.id).map(\.id))
        return workspace.session.floats.filter { tabWindows.contains($0.id) || $0.pinned }.reversed()
    }

    /// Tiled panes in reading order, then each window's front to back; a minimized window comes
    /// out when reached.
    func focusPane(offset: Int) {
        guard activeMixedTab == nil, let workspace, let tab = workspace.session.activeTab else { return }
        let tiled = workspace.session.tiledRoot(of: tab)?.panes ?? []
        let floating = floatsHidden ? [] : visibleWindows(in: workspace).flatMap(\.panes)
        let order = tiled + floating
        guard let index = order.firstIndex(of: tab.focused), order.count > 1 else { return }
        let next = order[(index + offset + order.count) % order.count]
        withAnimation(DS.Motion.snappy) { workspace.apply(.focus(next)) }
    }

    func cycleFloats() {
        guard let workspace else { return }
        let windows = visibleWindows(in: workspace)
        guard !windows.isEmpty else { return }
        if floatsHidden { floatsHidden = false }
        let focused = workspace.focusedPane.flatMap(workspace.window(of:))
        // The one after the focused window, or the frontmost.
        let next = focused.flatMap { focusedWindow in windows.firstIndex { $0.id == focusedWindow.id } }.map { windows[($0 + 1) % windows.count] } ?? windows[0]
        withAnimation(DS.Motion.snappy) { workspace.apply(.focus(next.panes[0])) }
    }

    /// Splits the focused pane along its longer side on screen.
    func splitBestFit() {
        guard let workspace, let pane = workspace.focusedPane else { return }
        let size = paneSize(pane, in: workspace)
        let action: WorkspaceAction = size.width >= size.height ? .splitRight : .splitDown
        action.perform(on: workspace, window: self)
    }

    func paneSize(_ pane: PaneId, in workspace: Workspace) -> CGSize {
        let area = CGRect(origin: .zero, size: terminalArea == .zero ? CGSize(width: 1200, height: 800) : terminalArea)
        let session = workspace.session
        guard let tab = session.tab(containing: pane) else { return area.size }
        if let window = session.window(containing: pane), let root = session.root(of: window) {
            return root.frames(in: FloatGeometry.rect(of: window.frame, in: area))[pane]?.size ?? area.size
        }
        return session.tiledRoot(of: tab)?.frames(in: area)[pane]?.size ?? area.size
    }

    /// A tiled pane moves past its neighbour that way; a floating window steps a twelfth of the tab.
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
        var probe = Session(tabs: [Tab(id: tab.id, root: tiled, focused: pane)], activeTabId: tab.id)
        probe.apply(.focusDirection(direction))
        guard let neighbour = probe.activeTab?.focused, neighbour != pane else { return }
        withAnimation(DS.Motion.lift) { workspace.apply(.movePane(pane, beside: neighbour, side: direction)) }
    }

    /// Grows a floating window that way; left and up shrink it.
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

    /// Moves the pane to a new tab in a new window; this window stays on the tab it showed.
    func popOut(_ pane: PaneId, in workspace: Workspace) {
        guard workspace.canMovePanes else { return }
        let before = currentTab
        let tabs = Set(workspace.session.tabs.map(\.id))
        if workspace.canMoveToNewTab(pane) {
            workspace.apply(.movePaneToNewTab(pane))
        }
        Task { @MainActor [weak self] in
            // Wait for the host to answer with the new tab.
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

    /// As the terminal tools and `gudo` name it (`p12`).
    func copyPaneId(_ pane: PaneId) {
        PaneIdPasteboard.copy("p\(pane.rawValue)")
        toasts.show(Toast("Copied p\(pane.rawValue)", systemImage: "doc.on.doc", style: .neutral))
    }

    /// Resets terminal state on this device and asks the program to redraw.
    func resetTerminal(_ pane: PaneId, in workspace: Workspace) {
        guard let terminal = workspace.panes[pane] else { return }
        terminal.view.surface.terminal.write(Array("\u{1b}c".utf8))
        [UInt8(0x0c)].withUnsafeBytes { terminal.backend.write($0) }
    }

    var focusedFloats: Bool {
        guard let workspace, let pane = workspace.focusedPane else { return false }
        return workspace.session.isFloating(pane)
    }
}

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
