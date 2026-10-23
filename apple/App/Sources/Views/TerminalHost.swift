import SwiftUI
import TerminalRenderer

#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// Hosts a pane's long-lived `TerminalView`. Each representable gets its own container, and the
/// pane's view lives in whichever of its containers is in a window (`Pane.placeView`). When the
/// split tree changes (split, zoom, tab switch) SwiftUI creates and removes containers in no
/// particular order; the view follows the one on screen, is never claimed by two representables,
/// and its surface survives. When the pane gains focus its view takes first responder, subject to
/// `Workspace.claimsKeyboardFocus`.
struct TerminalHost {
    let pane: Pane
    let isFocused: Bool
    let workspace: Workspace

    final class Coordinator {
        var wasFocused = false
    }

    /// Holds the pane's terminal view while on screen and keeps it at its own size.
    final class Container: PlatformView {
        weak var pane: Pane?

        #if os(macOS)
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            pane?.placeView(joining: window == nil ? nil : self)
        }

        /// Empty (the pane's view is in another container): transparent to the pointer, so a
        /// container on its way out, or not yet holding the view, never swallows clicks and wheel
        /// events meant for the terminal under it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            subviews.isEmpty ? nil : super.hitTest(point)
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            subviews.first?.frame = bounds
        }
        #else
        override func didMoveToWindow() {
            super.didMoveToWindow()
            pane?.placeView(joining: window == nil ? nil : self)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            subviews.isEmpty ? nil : super.hitTest(point, with: event)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            subviews.first?.frame = bounds
        }
        #endif
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeContainer() -> Container {
        let container = Container()
        container.pane = pane
        pane.hosts.add(container)
        return container
    }

    private func update(_ coordinator: Coordinator) {
        #if os(iOS)
        // The cursor follows the focused pane even while the software keyboard is down.
        pane.view.isSelected = isFocused
        #endif
        let claimsFocus = isFocused && !coordinator.wasFocused && workspace.claimsKeyboardFocus
        coordinator.wasFocused = isFocused
        guard claimsFocus else { return }
        let view = pane.view
        // The container joins its window after this update, so focus on a later turn: when the
        // split tree changes shape (a pane header appears, a pane moves) the view can take a few
        // turns to land in a window. Stop if focus moved on meanwhile.
        Task { @MainActor [workspace] in
            for attempt in 0..<20 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(16)) }
                guard workspace.focusedPane == pane.id else { return }
                #if os(macOS)
                if let window = view.window {
                    if window.firstResponder !== view { window.makeFirstResponder(view) }
                    return
                }
                #else
                if view.window != nil {
                    if !view.isFirstResponder { view.becomeFirstResponder() }
                    return
                }
                #endif
            }
        }
    }
}

extension Pane {
    /// Keeps `view` in a host container that is in a window: it moves to a container that joins
    /// the window its current one is in, and to another on-screen host when its container leaves
    /// the window; otherwise it stays put.
    ///
    /// The newcomer wins because SwiftUI rebuilds a pane's place (a NavigationStack swapping its
    /// root at launch, an identity change) by inserting the new representable on top and keeping
    /// the old one in the window while its removal animates, for most of a second. Staying in the
    /// old container then left the live, topmost one empty: the terminal sat under it, and wheel
    /// and clicks went to the empty container (less, vim and htop could not be scrolled).
    func placeView(joining newcomer: TerminalHost.Container? = nil) {
        let target: TerminalHost.Container
        if let current = view.superview as? TerminalHost.Container, current.window != nil, hosts.contains(current) {
            guard let newcomer, newcomer !== current, newcomer.window === current.window else { return }
            target = newcomer
        } else {
            guard let onScreen = hosts.allObjects.first(where: { $0.window != nil }) else { return }
            target = onScreen
        }
        // Moving the view resigns first responder; a terminal being typed into keeps the keyboard.
        #if os(macOS)
        let hadKeyboard = view.window?.firstResponder === view
        #else
        let hadKeyboard = view.isFirstResponder
        #endif
        view.removeFromSuperview()
        view.frame = target.bounds
        target.addSubview(view)
        #if os(macOS)
        // AppKit hands first responder to the window as soon as the old container leaves it, so
        // the view no longer knows it had the keyboard: the focused pane takes it back whenever
        // nothing else in the window has it. Only the focused pane: taking first responder
        // focuses the pane, and a pane moved into a new split (its sibling just took focus) had
        // the keyboard a moment ago.
        if let window = target.window, isFocusedPane(),
           hadKeyboard || window.firstResponder == nil || window.firstResponder === window
        {
            window.makeFirstResponder(view)
        }
        #else
        if hadKeyboard, isFocusedPane() { view.becomeFirstResponder() }
        #endif
        // Assistive technologies cache the element tree; tell them the terminal moved.
        #if os(macOS)
        NSAccessibility.post(element: target, notification: .layoutChanged)
        #else
        UIAccessibility.post(notification: .layoutChanged, argument: view)
        #endif
    }
}

// A terminal takes whatever space it is offered. Answering the size here keeps SwiftUI from
// measuring the platform view during its layout pass, which would run UIKit/AppKit layout (and the
// terminal's grid resize) inside SwiftUI's attribute-graph update.
#if os(macOS)
extension TerminalHost: NSViewRepresentable {
    func makeNSView(context: Context) -> Container { makeContainer() }
    func updateNSView(_ container: Container, context: Context) { update(context.coordinator) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#else
extension TerminalHost: UIViewRepresentable {
    func makeUIView(context: Context) -> Container { makeContainer() }
    func updateUIView(_ container: Container, context: Context) { update(context.coordinator) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#endif
