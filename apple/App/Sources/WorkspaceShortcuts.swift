#if os(macOS)
import AppKit
import TerminalRenderer
import SwiftUI

/// The workspace shortcuts (⌘T, ⌘D, ⇧⌘D, ⇧⌘[ …) handled before the menu bar, as Ghostty handles
/// its keybindings itself. SwiftUI's menu items can be stale when a key arrives (built lazily,
/// enabled state from a focused scene value that is briefly missing after a window rebuilds its
/// content), and a stale item silently drops the shortcut; the menu items stay for discovery and
/// clicks. Only the key window's workspace is acted on, and only when its terminal or the window
/// itself has the keyboard (a text field in a sheet keeps its own ⌘ keys).
@MainActor
enum WorkspaceShortcuts {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private static let actions = WorkspaceAction.fileActions + WorkspaceAction.paneActions + WorkspaceAction.drawActions + WorkspaceAction.tabActions
        + WorkspaceAction.historyActions + WorkspaceAction.floatActions + WorkspaceAction.browserActions

    private static func handle(_ event: NSEvent) -> Bool {
        if selectionKey(event) { return true }
        guard event.modifierFlags.contains(.command), let window = NSApp.keyWindow, window.attachedSheet == nil else { return false }
        // A VS Code pane has the keyboard: only the shortcuts that lead back out are the app's,
        // taken before the page could (the workbench would claim ⌘1 and ⌘W for itself).
        if let model = ActiveWindow.model(editingIn: window) {
            guard let action = action(for: event), action.passesEditor, let workspace = model.workspace else { return false }
            action.perform(on: workspace, window: model)
            return true
        }
        // A drawing has the keyboard: the keys that lead out of a page (⌘W, ⌘1–⌘9) are the app's
        // before the page sees them, as with VS Code.
        if let workspace = ActiveWindow.workspace(in: window), PaneDrawing.focusedCanvasHasKeyboard(in: workspace) {
            guard let action = action(for: event), action.passesEditor else { return false }
            action.perform(on: workspace, window: ActiveWindow.model(for: workspace))
            return true
        }
        guard window.firstResponder is TerminalView || window.firstResponder === window,
              let workspace = ActiveWindow.workspace(in: window), let action = action(for: event)
        else { return false }
        action.perform(on: workspace, window: ActiveWindow.model(for: workspace))
        return true
    }

    /// While tabs are selected in the sidebar: ⌘A selects every tab (not the terminal's text),
    /// Esc ends the selection. Text fields keep both.
    private static func selectionKey(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil,
              window.firstResponder is TerminalView || window.firstResponder === window,
              let workspace = ActiveWindow.workspace(in: window), let model = ActiveWindow.model(for: workspace),
              model.tabSelection.isMultiple || model.isSelectingTabs
        else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.isEmpty {
            model.endTabSelection()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
            model.selectAllTabs()
            return true
        }
        return false
    }

    private static func action(for event: NSEvent) -> WorkspaceAction? {
        var modifiers: EventModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let key = keyEquivalent(of: event)
        return actions.first { $0.shortcut.modifiers == modifiers && $0.shortcut.key == key }
    }

    /// The key as a menu would name it: arrows and Return by key, others by the character the
    /// layout produces without modifiers (so ⇧⌘[ is "[", not "{").
    private static func keyEquivalent(of event: NSEvent) -> KeyEquivalent? {
        switch event.specialKey {
        case .leftArrow?: return .leftArrow
        case .rightArrow?: return .rightArrow
        case .upArrow?: return .upArrow
        case .downArrow?: return .downArrow
        case .carriageReturn?, .enter?: return .return
        default: break
        }
        if event.keyCode == 36 || event.keyCode == 76 { return .return }
        guard let character = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers)?.lowercased().first
        else { return nil }
        return KeyEquivalent(character)
    }
}
#endif
