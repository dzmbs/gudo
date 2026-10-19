import PaneLayout
import SwiftUI

/// App actions with Ghostty's default shortcuts, shared by the menu commands and the pane menu.
/// Tab actions span every host in the window (`WindowModel`): ⌘T opens on the current host, ⌥⌘T
/// asks which host, ⌘1…⌘9 and ⇧⌘[ ] walk the unified list across hosts, ⌘P finds a tab anywhere.
enum WorkspaceAction: Hashable {
    case newTab, newTabOnHost, splitRight, splitDown, closePane
    case toggleZoom, focus(Direction), resize(Direction)
    case previousTab, nextTab, selectTab(Int), lastTab, goToTab

    static let fileActions: [Self] = [.newTab, .newTabOnHost, .splitRight, .splitDown, .closePane]
    static let paneActions: [Self] = [.toggleZoom] + Direction.allCases.map(Self.focus) + Direction.allCases.map(Self.resize)
    static let tabActions: [Self] = [.previousTab, .nextTab] + (1...8).map(Self.selectTab) + [.lastTab, .goToTab]

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newTabOnHost: "New Tab on Host…"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .closePane: "Close Pane"
        case .toggleZoom: "Zoom Pane"
        case .focus(let direction): "Select Pane \(direction.name)"
        case .resize(let direction): "Move Divider \(direction.name)"
        case .previousTab: "Show Previous Tab"
        case .nextTab: "Show Next Tab"
        case .selectTab(let number): "Tab \(number)"
        case .lastTab: "Last Tab"
        case .goToTab: "Go to Tab…"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .newTab: KeyboardShortcut("t")
        case .newTabOnHost: KeyboardShortcut("t", modifiers: [.command, .option])
        case .splitRight: KeyboardShortcut("d")
        case .splitDown: KeyboardShortcut("d", modifiers: [.command, .shift])
        case .closePane: KeyboardShortcut("w")
        case .toggleZoom: KeyboardShortcut(.return, modifiers: [.command, .shift])
        case .focus(let direction): KeyboardShortcut(direction.arrow, modifiers: [.command, .option])
        case .resize(let direction): KeyboardShortcut(direction.arrow, modifiers: [.command, .control])
        case .previousTab: KeyboardShortcut("[", modifiers: [.command, .shift])
        case .nextTab: KeyboardShortcut("]", modifiers: [.command, .shift])
        case .selectTab(let number): KeyboardShortcut(KeyEquivalent(Character("\(number)")))
        case .lastTab: KeyboardShortcut("9")
        case .goToTab: KeyboardShortcut("p")
        }
    }

    /// Runs the action in a window: tab actions go across the window's hosts; pane actions to
    /// the workspace on screen. Without a window (a menu item while SwiftUI reports none), tab
    /// actions stay within the workspace.
    func perform(on workspace: Workspace, window: WindowModel?) {
        guard let window else {
            perform(on: workspace)
            return
        }
        switch self {
        case .newTab: window.newTab()
        case .newTabOnHost: window.showHostPicker()
        case .previousTab: window.selectTab(offset: -1)
        case .nextTab: window.selectTab(offset: 1)
        case .selectTab(let number): window.selectTab(shortcut: number)
        case .lastTab: window.selectTab(shortcut: 9)
        case .goToTab: window.showTabFinder()
        default: perform(on: window.workspace ?? workspace)
        }
    }

    /// Runs the action on one workspace (its own tabs only).
    func perform(on workspace: Workspace) {
        switch self {
        case .newTab, .newTabOnHost: workspace.apply(.newTab)
        case .splitRight: workspace.split(.horizontal)
        case .splitDown: workspace.split(.vertical)
        case .closePane: workspace.closeFocusedPane()
        case .toggleZoom: workspace.apply(.toggleZoom)
        case .focus(let direction): workspace.apply(.focusDirection(direction))
        case .resize(let direction): workspace.resizeFocusedPane(direction)
        case .previousTab: workspace.selectTab(offset: -1)
        case .nextTab: workspace.selectTab(offset: 1)
        case .selectTab(let number): workspace.selectTab(at: number - 1)
        case .lastTab: workspace.selectTab(at: nil)
        case .goToTab: break
        }
    }
}

private extension Direction {
    var name: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Above"
        case .down: "Below"
        }
    }

    var arrow: KeyEquivalent {
        switch self {
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        }
    }
}
