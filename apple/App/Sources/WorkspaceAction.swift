import DesignSystem
import PaneLayout
import SwiftUI

/// App actions with Ghostty's default shortcuts, shared by the menu commands and the pane menu.
/// Tab actions span every host in the window (`WindowModel`): ⌘T opens on the current host, ⌥⌘T
/// asks which host, ⌘1…⌘9 and ⇧⌘[ ] walk the unified list across hosts, ⌘P finds a tab anywhere.
enum WorkspaceAction: Hashable {
    case newTab, newTabOnHost, splitRight, splitDown, closePane
    /// The New Agent sheet (Claude Code, Codex or a shell, optionally in its own worktree).
    case newAgent
    /// A pane on another host beside the focused one: the tab becomes a mixed tab.
    case splitWithHost
    case toggleZoom, focus(Direction), resize(Direction)
    /// The previous or next shell prompt at the top of the pane (Ghostty's `jump_to_prompt`).
    case previousPrompt, nextPrompt
    /// From a VS Code pane back to the terminal beside it, or the tab worked in before (⌃⌘`).
    case returnToTerminal
    /// The focused VS Code pane alone in the window, without the window's chrome (⌃⌘F).
    case fullScreenEditor
    case previousTab, nextTab, selectTab(Int), lastTab, goToTab
    case draw, newCanvas
    /// A new window with this window's hosts, on its tab (⌘N).
    case newWindow
    /// The window's own screens and overlays.
    case commandPalette, commandPaletteGhostty, find, links, inbox, hosts
    /// The next (older) and previous scrollback search match (⌘G / ⇧⌘G).
    case findNext, findPrevious
    case jumpToWaitingAgent
    /// Shows or hides the sidebar; hidden, the tabs are a strip on top (`TabPlacement`).
    case toggleSidebar
    /// Every shortcut on one page.
    case shortcuts

    static let fileActions: [Self] = [.newTab, .newTabOnHost, .newAgent, .splitRight, .splitDown, .splitWithHost, .closePane]
    static let paneActions: [Self] = [.toggleZoom] + Direction.allCases.map(Self.focus) + Direction.allCases.map(Self.resize)
        + [.previousPrompt, .nextPrompt, .returnToTerminal, .fullScreenEditor]
    static let drawActions: [Self] = [.draw, .newCanvas]
    static let tabActions: [Self] = [.previousTab, .nextTab] + (1...8).map(Self.selectTab) + [.lastTab, .goToTab]
    static let windowActions: [Self] = [.toggleSidebar, .shortcuts, .commandPalette, .commandPaletteGhostty, .find, .findNext, .findPrevious, .links, .inbox, .jumpToWaitingAgent, .hosts]
    /// Every app shortcut. The terminal answers these itself while it has the keyboard (iPad):
    /// UIKit asks the first responder first, so they never depend on the responder chain reaching
    /// the scene's menu commands, which it can miss right after the window switched hosts.
    static let allShortcutActions: [Self] = fileActions + paneActions + drawActions + tabActions + windowActions + [.newWindow]

    /// Whether the shortcut stays the app's while a VS Code pane has the keyboard
    /// (docs/APP-ARCHITECTURE.md §20): ⌘1–⌘9 switch tabs (VS Code's own ⌘1–⌘8 focus editor
    /// groups, which a browser takes for its tabs too), ⌘W closes the editor pane (as it closes
    /// vscode.dev's tab in a browser), ⌃⌘` goes back to the terminal. Every other key is VS
    /// Code's: ⌃Tab, ⇧⌘[ ], ⌥⌘arrows, ⌘P, ⌘K, ⌘B, ⌘D, ⌘F …
    var passesEditor: Bool {
        switch self {
        case .selectTab, .lastTab, .closePane, .returnToTerminal, .fullScreenEditor: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newTabOnHost: "New Tab on Host…"
        case .newAgent: "New Agent…"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .splitWithHost: "Split with Host…"
        case .closePane: "Close Pane"
        case .toggleZoom: "Zoom Pane"
        case .focus(let direction): "Select Pane \(direction.name)"
        case .resize(let direction): "Move Divider \(direction.name)"
        case .previousPrompt: "Jump to Previous Prompt"
        case .nextPrompt: "Jump to Next Prompt"
        case .returnToTerminal: "Return to Terminal"
        case .fullScreenEditor: "Full Screen Editor"
        case .previousTab: "Show Previous Tab"
        case .nextTab: "Show Next Tab"
        case .selectTab(let number): "Tab \(number)"
        case .lastTab: "Last Tab"
        case .goToTab: "Go to Tab…"
        case .draw: "Draw on Pane"
        case .newCanvas: "New Canvas Split"
        case .newWindow: "New Window"
        case .commandPalette, .commandPaletteGhostty: "Command Palette"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .links: "Links & Paths…"
        case .inbox: "Agents"
        case .jumpToWaitingAgent: "Jump to Waiting Agent"
        case .hosts: "Hosts"
        case .toggleSidebar: "Toggle Sidebar"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .newTab: KeyboardShortcut("t")
        case .newTabOnHost: KeyboardShortcut("t", modifiers: [.command, .option])
        // ⌘N is New Window; ⇧⌘N is free in the app and on iPadOS and macOS.
        case .newAgent: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .splitRight: KeyboardShortcut("d")
        case .splitDown: KeyboardShortcut("d", modifiers: [.command, .shift])
        // ⌥ is "on another host" (⌥⌘T); ⌥⌘D itself is the system's Dock shortcut on the Mac and
        // iPad, which never reaches the app, so Split with Host adds ⇧.
        case .splitWithHost: KeyboardShortcut("d", modifiers: [.command, .option, .shift])
        case .closePane: KeyboardShortcut("w")
        case .toggleZoom: KeyboardShortcut(.return, modifiers: [.command, .shift])
        case .focus(let direction): KeyboardShortcut(direction.arrow, modifiers: [.command, .option])
        case .resize(let direction): KeyboardShortcut(direction.arrow, modifiers: [.command, .control])
        case .previousPrompt: KeyboardShortcut(.upArrow, modifiers: .command)
        case .nextPrompt: KeyboardShortcut(.downArrow, modifiers: .command)
        // VS Code's ⌃` toggles its own terminal; ⌃⌘` is bound by neither VS Code nor the systems.
        // (⌘⎋ was tried: on iPad it never reaches the app past a focused web view.)
        case .returnToTerminal: KeyboardShortcut("`", modifiers: [.command, .control])
        // VS Code's own full-screen key on the Mac; the web workbench binds nothing to it.
        case .fullScreenEditor: KeyboardShortcut("f", modifiers: [.command, .control])
        case .previousTab: KeyboardShortcut("[", modifiers: [.command, .shift])
        case .nextTab: KeyboardShortcut("]", modifiers: [.command, .shift])
        case .selectTab(let number): KeyboardShortcut(KeyEquivalent(Character("\(number)")))
        case .lastTab: KeyboardShortcut("9")
        case .goToTab: KeyboardShortcut("p")
        // ⇧⌘D is Ghostty's Split Down.
        case .draw: KeyboardShortcut("d", modifiers: [.command, .control])
        case .newCanvas: KeyboardShortcut("d", modifiers: [.command, .control, .shift])
        case .newWindow: KeyboardShortcut("n")
        // ⌘K is Raycast's and Linear's; ⇧⌘P is Ghostty's.
        case .commandPalette: KeyboardShortcut("k")
        case .commandPaletteGhostty: KeyboardShortcut("p", modifiers: [.command, .shift])
        case .find: KeyboardShortcut("f")
        case .findNext: KeyboardShortcut("g")
        case .findPrevious: KeyboardShortcut("g", modifiers: [.command, .shift])
        case .links: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .inbox: KeyboardShortcut("i", modifiers: [.command, .shift])
        // ⇧⌘G is find previous (Ghostty, macOS); A for agent, free in the app and the systems.
        case .jumpToWaitingAgent: KeyboardShortcut("a", modifiers: [.command, .shift])
        case .hosts: KeyboardShortcut("h", modifiers: [.command, .shift])
        case .toggleSidebar: KeyboardShortcut("b")
        case .shortcuts: KeyboardShortcut("/")
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
        // A mixed tab's panes split, close, zoom and move focus in the mixed tab.
        if window.performInMixedTab(self) { return }
        switch self {
        case .newTab: window.newTab()
        case .newTabOnHost: window.showHostPicker()
        case .newAgent: window.newAgent()
        case .splitWithHost: window.showSplitWithHostPicker()
        case .previousTab: window.selectTab(offset: -1)
        case .nextTab: window.selectTab(offset: 1)
        case .selectTab(let number): window.selectTab(shortcut: number)
        case .lastTab: window.selectTab(shortcut: 9)
        case .goToTab: window.showTabFinder()
        case .newWindow: window.newWindow()
        case .commandPalette, .commandPaletteGhostty: window.isPaletteShown.toggle()
        case .find: window.isSearchShown = true
        case .findNext: window.findNext()
        case .findPrevious: window.findPrevious()
        case .links: window.sheet = .links
        case .inbox: window.destination = .inbox
        case .jumpToWaitingAgent: window.jumpToWaitingAgent()
        case .hosts: window.destination = window.destination == .hosts ? .terminal : .hosts
        case .toggleSidebar: perform(window: window)
        case .shortcuts: window.sheet = window.sheet == .shortcuts ? nil : .shortcuts
        case .returnToTerminal: window.returnToTerminal()
        case .fullScreenEditor: window.toggleEditorFullScreen()
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
        case .previousPrompt: PaneCommandMarks.jumpToPrompt(-1, in: workspace)
        case .nextPrompt: PaneCommandMarks.jumpToPrompt(1, in: workspace)
        case .previousTab: workspace.selectTab(offset: -1)
        case .nextTab: workspace.selectTab(offset: 1)
        case .selectTab(let number): workspace.selectTab(at: number - 1)
        case .lastTab: workspace.selectTab(at: nil)
        case .goToTab, .newWindow, .newAgent, .splitWithHost, .returnToTerminal, .fullScreenEditor: break
        case .draw: DrawingCommands.toggleDrawing(in: workspace)
        case .newCanvas: DrawingCommands.newCanvas(in: workspace)
        // Window screens need a window.
        case .commandPalette, .commandPaletteGhostty, .find, .findNext, .findPrevious, .links, .inbox, .jumpToWaitingAgent, .hosts, .toggleSidebar, .shortcuts: break
        }
    }

    /// Runs a window-only action (the sidebar toggle's own button has no workspace to hand).
    func perform(window: WindowModel) {
        switch self {
        case .toggleSidebar:
            withAnimation(DS.Motion.panel) { window.isSidebarShown.toggle() }
        default:
            if let workspace = window.workspace { perform(on: workspace, window: window) }
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
