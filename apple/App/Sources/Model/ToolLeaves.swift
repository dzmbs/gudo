import Foundation
import PaneLayout
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Files, Changes, Ports and Session Replays open as leaves of the window's split tree, beside
// the pane they came from rather than over it (a sheet) or apart from it (a window a tiling
// window manager would rearrange). iPhone and compact widths keep sheets: a split has no room.

extension ToolMember.Tool {
    init?(route: SheetRoute) {
        switch route {
        case .files: self = .files
        case .diff: self = .changes
        case .browser: self = .ports
        case .replays: self = .replays
        default: return nil
        }
    }

    var route: SheetRoute {
        switch self {
        case .files: .files
        case .changes: .diff
        case .ports: .browser
        case .replays: .replays
        }
    }

    var title: String { route.toolTitle }

    /// Mac: Pane ▸ Open in New Window for the focused tool leaf (⌘N's window, with ⌥: the
    /// modifier that opens a tool in a window of its own).
    static let newWindowShortcut = KeyboardShortcut("n", modifiers: [.command, .option])

    var systemImage: String {
        switch self {
        case .files: "folder"
        case .changes: "plusminus"
        case .ports: "globe"
        case .replays: "play.rectangle.on.rectangle"
        }
    }
}

extension WindowModel {
    /// Whether browsing tools open as leaves: the Mac and a regular-width iPad.
    var opensToolsAsLeaves: Bool {
        guard !isPresentation else { return false }
        #if os(macOS)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom == .pad && widthBucket != .compact
        #endif
    }

    /// Routes a tool asked for as a sheet (`sheet`'s setter): a leaf where tools are leaves, a
    /// window of its own on the Mac with ⌥ held. False when it stays a sheet.
    func presentTool(_ route: SheetRoute) -> Bool {
        guard let tool = ToolMember.Tool(route: route) else { return false }
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.option), openToolWindow(tool) { return true }
        #endif
        guard opensToolsAsLeaves else { return false }
        openToolLeaf(tool)
        return true
    }

    /// Shows a tool beside the focused pane: the leaf already showing it in this tab when there
    /// is one, else a new leaf to its right (a tab of its own when no tab is on screen).
    @discardableResult
    func openToolLeaf(_ tool: ToolMember.Tool) -> ToolMember {
        destination = .terminal
        if let mixed = activeMixed, let leaf = mixed.leaf(showing: tool), let member = mixed.tools[leaf] {
            focusLeaf(leaf, inMixedTab: mixed.id)
            return member
        }
        let member = ToolMember(hostId: currentGroupId, tool: tool)
        AppModel.log.info("\(tool.rawValue, privacy: .public) opens in a leaf")
        if let mixed = activeMixed {
            composites.addTool(member, to: mixed.id)
            syncMixedFocus()
        } else if let open = workspace, let tab = open.session.activeTab {
            let own = currentGroupId
            let id = composites.addTool(member, besideHost: own, tab: tab)
            if pairedTab == TabRef(hostId: own, tab: tab.id) { pairedTab = nil }
            activeMixedTab = id
            syncMixedFocus()
        } else {
            noteLeavingTab()
            focus(Self.mixedRef(composites.openTool(member)))
        }
        return member
    }

    func filesNavigator(for id: UUID, root: String) -> FilesNavigator {
        if let kept = filesNavigators[id] { return kept }
        let made = FilesNavigator(root: root)
        filesNavigators[id] = made
        return made
    }

    func closeTool(_ id: UUID) {
        filesNavigators[id] = nil
        guard let tab = composites.tab(containingTool: id), let leaf = tab.leaf(forTool: id) else { return }
        composites.close(leaf: leaf, in: tab.id)
        if activeMixedTab == tab.id { syncMixedFocus() }
    }

    /// Mac: the tool in a window of its own. False where there are none.
    @discardableResult
    func openToolWindow(_ tool: ToolMember.Tool) -> Bool {
        #if os(macOS)
        guard let openTool else { return false }
        openTool(ToolWindowRequest(route: tool.route.rawValue, window: serial))
        return true
        #else
        return false
        #endif
    }

    var focusedToolLeaf: ToolMember? {
        destination == .terminal ? activeMixed?.focusedTool : nil
    }

    /// Open in New Window from a tool leaf: the window takes over, the leaf closes.
    func moveToolToWindow(_ member: ToolMember) {
        guard openToolWindow(member.tool) else { return }
        closeTool(member.id)
    }

    /// A tool with no host to work on: Hosts, where one is connected (a sheet steps aside).
    func showHosts() {
        sheet = nil
        destination = .hosts
    }

    var hasToolWindows: Bool {
        #if os(macOS)
        openTool != nil
        #else
        false
        #endif
    }
}
