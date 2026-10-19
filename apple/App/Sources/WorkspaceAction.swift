import PaneLayout
import SwiftUI

/// App actions with Ghostty's default shortcuts, shared by the menu commands and the pane menu.
enum WorkspaceAction: Hashable {
    case newTab, splitRight, splitDown, closePane
    case toggleZoom, focus(Direction), resize(Direction)
    case previousTab, nextTab, selectTab(Int), lastTab
    case draw, newCanvas

    static let fileActions: [Self] = [.newTab, .splitRight, .splitDown, .closePane]
    static let paneActions: [Self] = [.toggleZoom] + Direction.allCases.map(Self.focus) + Direction.allCases.map(Self.resize)
    static let drawActions: [Self] = [.draw, .newCanvas]
    static let tabActions: [Self] = [.previousTab, .nextTab] + (1...8).map(Self.selectTab) + [.lastTab]

    var title: String {
        switch self {
        case .newTab: "New Tab"
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
        case .draw: "Draw on Pane"
        case .newCanvas: "New Canvas Split"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .newTab: KeyboardShortcut("t")
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
        // ⇧⌘D is Ghostty's Split Down.
        case .draw: KeyboardShortcut("d", modifiers: [.command, .control])
        case .newCanvas: KeyboardShortcut("d", modifiers: [.command, .control, .shift])
        }
    }

    func perform(on workspace: Workspace) {
        switch self {
        case .newTab: workspace.apply(.newTab)
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
        case .draw: DrawingCommands.toggleDrawing(in: workspace)
        case .newCanvas: DrawingCommands.newCanvas(in: workspace)
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
