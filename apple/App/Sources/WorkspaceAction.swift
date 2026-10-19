import PaneLayout
import SwiftUI

/// App actions with Ghostty's default shortcuts, shared by the menu commands and the pane menu.
/// Tab actions span every host in the window (`WindowModel`): ⌘T opens on the current host, ⌥⌘T
/// asks which host, ⌘1…⌘9 and ⇧⌘[ ] walk the unified list across hosts, ⌘P finds a tab anywhere.
enum WorkspaceAction: Hashable {
    case newTab, newTabOnHost, splitRight, splitDown, closePane
    case toggleZoom, focus(Direction), resize(Direction)
    case previousTab, nextTab, selectTab(Int), lastTab, goToTab
    case draw, newCanvas
    /// The window's own screens and overlays.
    case commandPalette, commandPaletteGhostty, find, links, inbox, hosts

    static let fileActions: [Self] = [.newTab, .newTabOnHost, .splitRight, .splitDown, .closePane]
    static let paneActions: [Self] = [.toggleZoom] + Direction.allCases.map(Self.focus) + Direction.allCases.map(Self.resize)
    static let drawActions: [Self] = [.draw, .newCanvas]
    static let tabActions: [Self] = [.previousTab, .nextTab] + (1...8).map(Self.selectTab) + [.lastTab, .goToTab]
    static let windowActions: [Self] = [.commandPalette, .commandPaletteGhostty, .find, .links, .inbox, .hosts]
    /// Every app shortcut. The terminal answers these itself while it has the keyboard (iPad):
    /// UIKit asks the first responder first, so they never depend on the responder chain reaching
    /// the scene's menu commands, which it can miss right after the window switched hosts.
    static let allShortcutActions: [Self] = fileActions + paneActions + drawActions + tabActions + windowActions

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
        case .draw: "Draw on Pane"
        case .newCanvas: "New Canvas Split"
        case .commandPalette, .commandPaletteGhostty: "Command Palette"
        case .find: "Find…"
        case .links: "Links & Paths…"
        case .inbox: "Inbox"
        case .hosts: "Hosts"
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
        // ⇧⌘D is Ghostty's Split Down.
        case .draw: KeyboardShortcut("d", modifiers: [.command, .control])
        case .newCanvas: KeyboardShortcut("d", modifiers: [.command, .control, .shift])
        // ⌘K is Raycast's and Linear's; ⇧⌘P is Ghostty's.
        case .commandPalette: KeyboardShortcut("k")
        case .commandPaletteGhostty: KeyboardShortcut("p", modifiers: [.command, .shift])
        case .find: KeyboardShortcut("f")
        case .links: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .inbox: KeyboardShortcut("i", modifiers: [.command, .shift])
        case .hosts: KeyboardShortcut("h", modifiers: [.command, .shift])
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
        case .commandPalette, .commandPaletteGhostty: window.isPaletteShown.toggle()
        case .find: window.isSearchShown = true
        case .links: window.sheet = .links
        case .inbox: window.destination = .inbox
        case .hosts: window.destination = window.destination == .hosts ? .terminal : .hosts
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
        case .draw: DrawingCommands.toggleDrawing(in: workspace)
        case .newCanvas: DrawingCommands.newCanvas(in: workspace)
        // Window screens need a window.
        case .commandPalette, .commandPaletteGhostty, .find, .links, .inbox, .hosts: break
        }
    }
}

#if os(iOS)
import UIKit

extension KeyEquivalent {
    /// The same key as a `UIKeyCommand` input (arrows and Return have named inputs).
    var uiKeyInput: String {
        switch self {
        case .upArrow: UIKeyCommand.inputUpArrow
        case .downArrow: UIKeyCommand.inputDownArrow
        case .leftArrow: UIKeyCommand.inputLeftArrow
        case .rightArrow: UIKeyCommand.inputRightArrow
        case .return: "\r"
        default: String(character)
        }
    }
}

extension EventModifiers {
    /// The same modifiers as UIKit key-command flags.
    var uiKeyModifierFlags: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.alternate) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
#endif

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
