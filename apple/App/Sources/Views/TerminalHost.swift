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
        // The container joins its window after this update, so focus on the next turn.
        Task { @MainActor in
            #if os(macOS)
            if let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
            #else
            if view.window != nil, !view.isFirstResponder { view.becomeFirstResponder() }
            #endif
        }
    }
}

extension Pane {
    /// Keeps `view` in a host container that is in a window: it stays put while its container is
    /// on screen, and moves to another on-screen host when its container leaves the window.
    func placeView() {
        if let current = view.superview as? TerminalHost.Container, current.window != nil, hosts.contains(current) { return }
        guard let target = hosts.allObjects.first(where: { $0.window != nil }) else { return }
        view.removeFromSuperview()
        view.frame = target.bounds
        target.addSubview(view)
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
