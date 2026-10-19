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

    private static let actions = WorkspaceAction.fileActions + WorkspaceAction.paneActions + WorkspaceAction.tabActions

    private static func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let window = NSApp.keyWindow, window.attachedSheet == nil,
              window.firstResponder is TerminalView || window.firstResponder === window,
              let workspace = ActiveWindow.workspace(in: window), let action = action(for: event)
        else { return false }
        action.perform(on: workspace)
        return true
    }

    private static func action(for event: NSEvent) -> WorkspaceAction? {
        var mods: EventModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        let key = keyEquivalent(of: event)
        return actions.first { $0.shortcut.modifiers == mods && $0.shortcut.key == key }
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
