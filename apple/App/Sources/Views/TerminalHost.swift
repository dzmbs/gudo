import SwiftUI
import TerminalRenderer

#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// Hosts a pane's long-lived `TerminalView`. Each representable gets its own container and the
/// view lives in an active container in a window (`Pane.placeView`), because SwiftUI creates and
/// removes containers in no particular order when the split tree changes.
struct TerminalHost {
    let pane: Pane
    let isFocused: Bool
    let workspace: Workspace
    var isActive = true

    final class Coordinator {
        var wasFocused = false
    }

    /// Holds the pane's terminal view while on screen and keeps it at its own size.
    final class Container: PlatformView {
        weak var pane: Pane?
        var isFocusedPane = false
        var isActive = true {
            didSet {
                guard isActive != oldValue, let pane else { return }
                if isActive, window != nil { pane.placeView(joining: self) }
                else if !isActive, pane.view.superview === self { pane.view.removeFromSuperview() }
            }
        }

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
        container.isFocusedPane = isFocused
        container.isActive = isActive
        container.pane = pane
        pane.hosts.add(container)
        return container
    }

    private func update(_ container: Container, coordinator: Coordinator) {
        container.isFocusedPane = isFocused
        container.isActive = isActive
        if isActive { pane.placeView(joining: container) }
        #if os(iOS)
        // A retiring container must not change the selection of the view in its new host.
        if pane.view.superview === container { pane.view.isSelected = isFocused && isActive }
        #endif
        let gainedFocus = isActive && isFocused && !coordinator.wasFocused
        coordinator.wasFocused = isActive && isFocused
        guard gainedFocus, workspace.claimsKeyboardFocus || PaneDrawing.canvas(in: pane) != nil else { return }
        let view = pane.view
        // The container joins its window after this update, so focus on a later turn: when the
        // split tree changes shape (a pane header appears, a pane moves) the view can take a few
        // turns to land in a window. Stop if focus moved on meanwhile.
        Task { @MainActor [workspace] in
            for attempt in 0..<20 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(16)) }
                guard container.isActive, workspace.focusedPane == pane.id else { return }
                if let canvas = PaneDrawing.canvas(in: pane) {
                    canvas.takeKeyboard()
                    return
                }
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
    /// Keeps `view` in an active host container in a window, preferring a newcomer joining the
    /// same window.
    ///
    /// The newcomer wins because SwiftUI rebuilds a pane's place by inserting the new
    /// representable on top and keeping the old one in the window while its removal animates.
    /// Staying in the old container would leave the topmost one empty, swallowing wheel and clicks.
    func placeView(joining newcomer: TerminalHost.Container? = nil) {
        if let newcomer, !newcomer.isActive { return }
        let target: TerminalHost.Container
        if let current = view.superview as? TerminalHost.Container, current.isActive, current.window != nil, hosts.contains(current) {
            guard let newcomer, newcomer !== current, newcomer.window === current.window else { return }
            target = newcomer
        } else {
            guard let onScreen = hosts.allObjects.first(where: { $0.isActive && $0.window != nil }) else { return }
            target = onScreen
        }
        // Moving the view resigns first responder; a terminal being typed into keeps the keyboard.
        let canvas = PaneDrawing.canvas(in: self)
        #if os(macOS)
        let hadKeyboard = canvas?.ownsKeyboard ?? (view.window?.firstResponder === view)
        #else
        let hadKeyboard = canvas?.ownsKeyboard ?? view.isFirstResponder
        #endif
        view.removeFromSuperview()
        view.frame = target.bounds
        target.addSubview(view)
        #if os(iOS)
        view.isSelected = target.isFocusedPane
        #endif
        #if os(macOS)
        // AppKit hands first responder to the window as soon as the old container leaves it, so
        // the focused pane takes it back whenever nothing else in the window has it. Only the
        // focused pane: taking first responder focuses the pane.
        guard let window = target.window, isFocusedPane(),
              hadKeyboard || window.firstResponder == nil || window.firstResponder === window
        else { return announceMove(to: target) }
        if let canvas { canvas.takeKeyboard() } else { window.makeFirstResponder(view) }
        #else
        if hadKeyboard, isFocusedPane() {
            if let canvas { canvas.takeKeyboard() } else { view.becomeFirstResponder() }
        }
        #endif
        announceMove(to: target)
    }

    private func announceMove(to target: TerminalHost.Container) {
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
    func updateNSView(_ container: Container, context: Context) { update(container, coordinator: context.coordinator) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#else
extension TerminalHost: UIViewRepresentable {
    func makeUIView(context: Context) -> Container { makeContainer() }
    func updateUIView(_ container: Container, context: Context) { update(container, coordinator: context.coordinator) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
#endif
