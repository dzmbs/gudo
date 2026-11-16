import PaneLayout
import SwiftUI
import TerminalRenderer
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Who had the keyboard when an overlay took it, so it goes back there when the overlay closes.
struct OverlayKeyboard {
    #if os(macOS)
    typealias Responder = NSResponder
    #else
    typealias Responder = UIResponder
    #endif

    #if os(macOS)
    typealias PlatformWindow = NSWindow
    #else
    typealias PlatformWindow = UIWindow
    #endif

    private(set) var isHeld = false
    private weak var responder: Responder?
    private weak var window: PlatformWindow?
    private var focusedPane: PaneId?

    mutating func take(from workspace: Workspace?) {
        isHeld = true
        focusedPane = workspace?.focusedPane
        window = workspace.flatMap(Self.window(of:))
        responder = window.flatMap(Self.keyboardOwner(in:))
    }

    /// Where the keyboard goes now that the overlay is gone: back to whoever had it, or to the
    /// focused pane if focus moved meanwhile (a tab chosen in Go to Tab), or if nothing had it.
    mutating func release(to workspace: Workspace?) -> (Responder, PlatformWindow)? {
        isHeld = false
        defer { responder = nil }
        guard let workspace else { return nil }
        let window = window ?? Self.window(of: workspace)
        guard let window else { return nil }
        let paneView = workspace.focusedPane.flatMap { workspace.pane($0)?.view }
        if workspace.focusedPane == focusedPane, let responder, Self.isInWindow(responder, window) {
            return (responder, window)
        }
        #if os(iOS)
        // The software keyboard comes back only for a terminal that had it.
        guard responder is TerminalView || workspace.claimsKeyboardFocus else { return nil }
        #endif
        guard let paneView, paneView.window === window else { return nil }
        return (paneView, window)
    }

    private static func window(of workspace: Workspace) -> PlatformWindow? {
        if let id = workspace.focusedPane, let window = workspace.pane(id)?.view.window { return window }
        return workspace.panes.values.lazy.compactMap(\.view.window).first
    }

    #if os(macOS)
    private static func keyboardOwner(in window: NSWindow) -> NSResponder? {
        guard let owner = window.firstResponder, owner !== window else { return nil }
        // The window's shared field editor stands for the text field it edits.
        if let editor = owner as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder { return field }
        return owner
    }

    private static func isInWindow(_ responder: NSResponder, _ window: NSWindow) -> Bool {
        (responder as? NSView)?.window === window
    }
    #else
    private static func keyboardOwner(in window: UIWindow) -> UIResponder? {
        window.firstResponderWithin()
    }

    private static func isInWindow(_ responder: UIResponder, _ window: UIWindow) -> Bool {
        (responder as? UIView)?.window === window
    }
    #endif
}

extension WindowModel {
    /// A palette, panel, sheet or prompt over the window has the keyboard. While it does, no
    /// terminal can take it (not even one that appears or gains focus meanwhile), and when it
    /// closes the keyboard goes back to where it was.
    var overlayHoldsKeyboard: Bool {
        isPaletteShown || workflowPanel != nil || sheet != nil || isHostSwitcherShown || workspace?.renamingTab != nil
    }

    /// Follows `overlayHoldsKeyboard`; called whenever one of its parts changes.
    func overlayKeyboardChanged() {
        let holds = overlayHoldsKeyboard
        guard holds != overlayKeyboard.isHeld else { return }
        if holds {
            overlayKeyboard.take(from: workspace)
            for open in workspaces.values { open.refusesKeyboard = true }
        } else {
            for open in workspaces.values { open.refusesKeyboard = false }
            guard let (responder, window) = overlayKeyboard.release(to: workspace) else { return }
            #if os(macOS)
            window.makeFirstResponder(responder)
            #else
            _ = window
            responder.becomeFirstResponder()
            #endif
        }
    }

    /// Return to Terminal and focus moves with nowhere new to go: the focused pane takes the
    /// keyboard if nothing has it.
    func giveKeyboardToFocusedPane() {
        guard !overlayHoldsKeyboard, let workspace, let id = workspace.focusedPane, let view = workspace.pane(id)?.view else { return }
        #if os(macOS)
        guard let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
        #else
        guard view.window != nil, !view.isFirstResponder, workspace.claimsKeyboardFocus else { return }
        view.becomeFirstResponder()
        #endif
    }
}
