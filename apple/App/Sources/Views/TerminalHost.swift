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
            pane?.placeView()
        }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            subviews.first?.frame = bounds
        }
        #else
        override func didMoveToWindow() {
            super.didMoveToWindow()
            pane?.placeView()
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
    /// Keeps `view` in a host container that is in a window: it stays put while its container is
    /// on screen, and moves to another on-screen host when its container leaves the window.
    func placeView() {
        if let current = view.superview as? TerminalHost.Container, current.window != nil, hosts.contains(current) { return }
        guard let target = hosts.allObjects.first(where: { $0.window != nil }) else { return }
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
        // nothing else in the window has it.
        if let window = target.window,
           hadKeyboard || (isFocusedPane() && (window.firstResponder == nil || window.firstResponder === window))
        {
            window.makeFirstResponder(view)
        }
        #else
        if hadKeyboard { view.becomeFirstResponder() }
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
