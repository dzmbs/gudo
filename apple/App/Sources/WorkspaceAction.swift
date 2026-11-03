import DesignSystem
import PaneLayout
import SwiftUI

/// App actions with Ghostty's default shortcuts, shared by the menu commands and the pane menu.
/// Tab actions span every host in the window (`WindowModel`): ⌘T opens on the current host, ⌥⌘T
/// asks which host, ⌘1…⌘9 and ⇧⌘[ ] walk the unified list across hosts, ⌘P finds a tab anywhere.
enum WorkspaceAction: Hashable {
    case newTab, newTabOnHost, splitRight, splitDown, closePane
    /// An empty project in the sidebar, its name typed in place.
    case newProject
    /// The New Agent sheet (Claude Code, Codex or a shell, optionally in its own worktree).
    case newAgent
    /// A pane on another host beside the focused one: the tab becomes a mixed tab.
    case splitWithHost
    case toggleZoom, focus(Direction), resize(Direction)
    /// The focused pane leaves for a new tab right after its own.
    case movePaneToNewTab
    /// Scrolls the previous or next shell prompt to the top of the pane.
    case previousPrompt, nextPrompt
    /// From a VS Code pane back to the terminal beside it, or the tab worked in before (⌃⌘`).
    case returnToTerminal
    /// The focused VS Code pane alone in the window, without the window's chrome (⌃⌘F).
    case fullScreenEditor
    case previousTab, nextTab, selectTab(Int), lastTab, goToTab
    case moveTabUp, moveTabDown
    case selectHost(Int)
    /// A sketch on the focused pane, and a standalone drawing in a floating canvas window.
    case draw, newDrawing
    /// A new window with this window's hosts, on its tab.
    case newWindow
    case commandPalette, commandPaletteGhostty, find, links, inbox, hosts
    /// The next (older) and previous scrollback search match.
    case findNext, findPrevious
    /// Shows the agent that has waited longest for you.
    case jumpToWaitingAgent
    /// Shows or hides the sidebar; hidden, the tabs are a strip on top (`TabPlacement`).
    case toggleSidebar
    case shortcuts
    /// The last closed tab (or tabs closed together) back where it was.
    case reopenClosedTab
    /// Float or dock the focused pane, send its window to the tray, bring the next window
    /// forward, look under them all.
    case toggleFloat, minimizeFloat, cycleFloats, toggleFloatsHidden
    /// The next or previous pane, tiled panes then windows.
    case focusNextPane, focusPreviousPane
    /// The focused pane trades places past its neighbour; a floating window steps that way.
    case movePane(Direction)
    /// A split along the focused pane's longer side.
    case splitBestFit
    /// A browser beside the focused pane, on the dev server it runs.
    case openBrowser

    static let fileActions: [Self] = [.newTab, .newTabOnHost, .newAgent, .newProject, .splitRight, .splitDown, .splitWithHost, .closePane]
    static let paneActions: [Self] = [.toggleZoom, .splitBestFit, .movePaneToNewTab] + Direction.allCases.map(Self.focus)
        + [.focusNextPane, .focusPreviousPane] + Direction.allCases.map(Self.movePane) + Direction.allCases.map(Self.resize)
        + [.previousPrompt, .nextPrompt, .returnToTerminal, .fullScreenEditor]
    static let floatActions: [Self] = [.toggleFloat, .minimizeFloat, .cycleFloats, .toggleFloatsHidden]
    static let drawActions: [Self] = [.draw, .newDrawing]
    static let browserActions: [Self] = [.openBrowser]
    static let tabActions: [Self] = [.previousTab, .nextTab] + (1...8).map(Self.selectTab) + [.lastTab, .goToTab, .moveTabUp, .moveTabDown]
    static let hostActions: [Self] = (1...9).map(Self.selectHost)
    static let historyActions: [Self] = [.reopenClosedTab]
    static let windowActions: [Self] = [.toggleSidebar, .shortcuts, .commandPalette, .commandPaletteGhostty, .find, .findNext, .findPrevious, .links, .inbox, .jumpToWaitingAgent, .hosts]
    /// Every app shortcut. The terminal answers these itself while it has the keyboard (iPad):
    /// UIKit asks the first responder first, so they never depend on the responder chain reaching
    /// the scene's menu commands, which it can miss right after the window switched hosts.
    static let allShortcutActions: [Self] = fileActions + paneActions + drawActions + browserActions + tabActions + hostActions + windowActions + historyActions + floatActions + [.newWindow]

    /// Whether the shortcut stays the app's while a VS Code pane has the keyboard:
    /// ⌘1–⌘9 switch tabs (VS Code's own ⌘1–⌘8 focus editor
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
        case .newProject: "New Project"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .splitWithHost: "Split with Host…"
        case .closePane: "Close Pane"
        case .toggleZoom: "Zoom Pane"
        case .movePaneToNewTab: "Move Pane to New Tab"
        case .focus(let direction): "Select Pane \(direction.name)"
        case .resize(let direction): "Move Divider \(direction.name)"
        case .previousPrompt: "Jump to Previous Prompt"
        case .nextPrompt: "Jump to Next Prompt"
        case .returnToTerminal: "Return to Terminal"
        case .fullScreenEditor: "Full Screen Editor"
        case .previousTab: "Show Previous Tab"
        case .nextTab: "Show Next Tab"
        case .selectTab(let number): "Tab \(number)"
        case .selectHost(let number): "Host \(number)"
        case .lastTab: "Last Tab"
        case .goToTab: "Go to Tab…"
        case .moveTabUp: "Move Tab Up"
        case .moveTabDown: "Move Tab Down"
        case .draw: "Sketch on Pane"
        case .newDrawing: "New Drawing"
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
        case .reopenClosedTab: "Reopen Closed Tab"
        case .toggleFloat: "Float or Dock Pane"
        case .minimizeFloat: "Minimize Floating Window"
        case .cycleFloats: "Next Floating Window"
        case .toggleFloatsHidden: "Hide or Show Floating Windows"
        case .focusNextPane: "Focus Next Pane"
        case .focusPreviousPane: "Focus Previous Pane"
        case .movePane(let direction): "Move Pane \(direction.moveName)"
        case .splitBestFit: "Split Pane Best Fit"
        case .openBrowser: "Open Browser Beside"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .newTab: KeyboardShortcut("t")
        case .newTabOnHost: KeyboardShortcut("t", modifiers: [.command, .option])
        // ⌘N is New Window; ⇧⌘N is free in the app and on iPadOS and macOS.
        case .newAgent: KeyboardShortcut("n", modifiers: [.command, .shift])
        // Safari's New Empty Tab Group (⌥⌘N is Open in New Window for a tool pane).
        case .newProject: KeyboardShortcut("n", modifiers: [.command, .control])
        case .splitRight: KeyboardShortcut("d")
        case .splitDown: KeyboardShortcut("d", modifiers: [.command, .shift])
        // ⌥ is "on another host" (⌥⌘T); ⌥⌘D itself is the system's Dock shortcut on the Mac and
        // iPad, which never reaches the app, so Split with Host adds ⇧.
        case .splitWithHost: KeyboardShortcut("d", modifiers: [.command, .option, .shift])
        case .closePane: KeyboardShortcut("w")
        case .toggleZoom: KeyboardShortcut(.return, modifiers: [.command, .shift])
        // ⇧⌘T is every browser's Reopen Closed Tab; ⌥ adds "take the pane along" to it.
        case .movePaneToNewTab: KeyboardShortcut("t", modifiers: [.command, .option, .shift])
        case .focus(let direction): KeyboardShortcut(direction.arrow, modifiers: [.command, .option])
        case .resize(let direction): KeyboardShortcut(direction.arrow, modifiers: [.command, .control])
        case .previousPrompt: KeyboardShortcut(.upArrow, modifiers: .command)
        case .nextPrompt: KeyboardShortcut(.downArrow, modifiers: .command)
        // VS Code's ⌃` toggles its own terminal; ⌃⌘` is bound by neither VS Code nor the systems.
        // ⌘⎋ would not do: on iPad it never reaches the app past a focused web view.
        case .returnToTerminal: KeyboardShortcut("`", modifiers: [.command, .control])
        // VS Code's own full-screen key on the Mac; the web workbench binds nothing to it.
        case .fullScreenEditor: KeyboardShortcut("f", modifiers: [.command, .control])
        case .previousTab: KeyboardShortcut("[", modifiers: [.command, .shift])
        case .nextTab: KeyboardShortcut("]", modifiers: [.command, .shift])
        case .selectTab(let number): KeyboardShortcut(KeyEquivalent(Character("\(number)")))
        case .selectHost(let number): KeyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [.command, .control])
        case .lastTab: KeyboardShortcut("9")
        case .goToTab: KeyboardShortcut("p")
        // ⌃⌘arrows move dividers (Ghostty); ⇧ moves the tab instead.
        case .moveTabUp: KeyboardShortcut(.upArrow, modifiers: [.command, .control, .shift])
        case .moveTabDown: KeyboardShortcut(.downArrow, modifiers: [.command, .control, .shift])
        // ⇧⌘D is Ghostty's Split Down.
        case .draw: KeyboardShortcut("d", modifiers: [.command, .control])
        case .newDrawing: KeyboardShortcut("d", modifiers: [.command, .control, .shift])
        case .newWindow: KeyboardShortcut("n")
        // ⇧⌘P is Ghostty's palette key.
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
        // VS Code's sidebar key; AppKit's ⌃⌘S is left free for the terminal.
        case .toggleSidebar: KeyboardShortcut("b")
        case .shortcuts: KeyboardShortcut("/")
        case .reopenClosedTab: KeyboardShortcut("t", modifiers: [.command, .shift])
        // ⇧⌘↩ beside it is Zoom (Ghostty).
        case .toggleFloat: KeyboardShortcut(.return, modifiers: [.command, .option])
        // ⌘M and ⌥⌘M are the system's own window minimize.
        case .minimizeFloat: KeyboardShortcut("m", modifiers: [.command, .shift])
        // ⌘] / ⌘[ walk every pane (Ghostty's goto_split next/previous); ⌥ keeps to windows.
        case .cycleFloats: KeyboardShortcut("]", modifiers: [.command, .option])
        // ⌥⌘H is the Mac's Hide Others; F for floating, free in the app and the systems.
        case .toggleFloatsHidden: KeyboardShortcut("f", modifiers: [.command, .option])
        case .focusNextPane: KeyboardShortcut("]")
        case .focusPreviousPane: KeyboardShortcut("[")
        // ⌥⌘arrows move focus and ⌃⌘arrows dividers; ⇧ takes the pane along.
        case .movePane(let direction): KeyboardShortcut(direction.arrow, modifiers: [.command, .option, .shift])
        case .splitBestFit: KeyboardShortcut(.return, modifiers: .command)
        // Free in the app and the systems; ⌘B beside it is the sidebar.
        case .openBrowser: KeyboardShortcut("b", modifiers: [.command, .shift])
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
        case .newProject: withAnimation(DS.Motion.reorder) { window.newEmptyProject() }
        case .splitWithHost: window.showSplitWithHostPicker()
        case .previousTab: window.selectTab(offset: -1)
        case .nextTab: window.selectTab(offset: 1)
        case .selectTab(let number): window.selectTab(shortcut: number)
        case .selectHost(let number): window.selectHost(number: number)
        case .lastTab: window.selectTab(shortcut: 9)
        case .goToTab: window.showTabFinder()
        case .moveTabUp: withAnimation(DS.Motion.reorder) { window.moveCurrentTab(by: -1) }
        case .moveTabDown: withAnimation(DS.Motion.reorder) { window.moveCurrentTab(by: 1) }
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
        case .reopenClosedTab: window.reopenLastClosed()
        case .toggleFloat: window.toggleFloat()
        case .minimizeFloat: window.toggleMinimized()
        case .cycleFloats: window.cycleFloats()
        case .toggleFloatsHidden: window.toggleFloatsHidden()
        case .focusNextPane: window.focusPane(offset: 1)
        case .focusPreviousPane: window.focusPane(offset: -1)
        case .movePane(let direction): window.movePane(direction)
        case .splitBestFit: window.splitBestFit()
        case .openBrowser: window.openBrowserBesideFocusedPane()
        case .resize(let direction) where window.focusedFloats: _ = window.resizeFloat(direction)
        case .closePane: window.closeFocusedPaneOrTab()
        case .returnToTerminal: window.returnToTerminal()
        case .fullScreenEditor: window.toggleEditorFullScreen()
        case .movePaneToNewTab: window.movePaneToNewTab()
        case .newDrawing: DrawingDocuments.newDrawing(window: window)
        default: perform(on: window.workspace ?? workspace)
        }
    }

    func perform(on workspace: Workspace) {
        switch self {
        case .newTab, .newTabOnHost: workspace.apply(.newTab)
        case .splitRight: workspace.split(.horizontal)
        case .splitDown: workspace.split(.vertical)
        case .closePane: workspace.closeFocusedPane()
        case .toggleZoom: workspace.apply(.toggleZoom)
        case .movePaneToNewTab: if let pane = workspace.focusedPane, workspace.canMoveToNewTab(pane) { workspace.apply(.movePaneToNewTab(pane)) }
        case .focus(let direction): workspace.apply(.focusDirection(direction))
        case .resize(let direction): workspace.resizeFocusedPane(direction)
        case .previousPrompt: PaneCommandMarks.jumpToPrompt(-1, in: workspace)
        case .nextPrompt: PaneCommandMarks.jumpToPrompt(1, in: workspace)
        case .previousTab: workspace.selectTab(offset: -1)
        case .nextTab: workspace.selectTab(offset: 1)
        case .selectTab(let number): workspace.selectTab(at: number - 1)
        case .lastTab: workspace.selectTab(at: nil)
        case .goToTab, .moveTabUp, .moveTabDown, .newWindow, .newAgent, .newProject, .splitWithHost, .returnToTerminal, .fullScreenEditor, .selectHost, .reopenClosedTab: break
        case .toggleFloat, .minimizeFloat, .cycleFloats, .toggleFloatsHidden, .movePane, .openBrowser: break
        case .focusNextPane: workspace.apply(.focusDirection(.right))
        case .focusPreviousPane: workspace.apply(.focusDirection(.left))
        case .splitBestFit: workspace.split(.horizontal)
        case .draw: DrawingCommands.toggleDrawing(in: workspace)
        case .newDrawing: if let window = ActiveWindow.model { DrawingDocuments.newDrawing(window: window) }
        case .commandPalette, .commandPaletteGhostty, .find, .findNext, .findPrevious, .links, .inbox, .jumpToWaitingAgent, .hosts, .toggleSidebar, .shortcuts: break
        }
    }

    /// Runs a window-only action (the sidebar toggle's own button has no workspace to hand).
    func perform(window: WindowModel) {
        switch self {
        case .toggleSidebar:
            withAnimation(DS.Motion.sidebar) { window.isSidebarShown.toggle() }
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
    var moveName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }

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
