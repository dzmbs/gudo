#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Runs `action` for Esc (and ⌘., Esc on a keyboard without one) from a hardware keyboard,
    /// even while a text field has the keyboard: iOS gives a field's own SwiftUI key handlers and
    /// shortcuts no Esc. The command sits on the view controller holding this view, ahead of the
    /// system's text handling, for as long as the view is in a window.
    func onEscapeKey(perform action: @escaping () -> Void) -> some View {
        background(EscapeKeyCommand(action: action).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct EscapeKeyCommand: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ anchor: Anchor, context: Context) {
        anchor.action = action
    }

    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) {
        anchor.uninstall()
    }

    final class Anchor: UIView {
        var action: (() -> Void)?
        private weak var controller: UIViewController?
        private var commands: [UIKeyCommand] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { uninstall() } else { install() }
        }

        private func install() {
            guard controller == nil, let owner = sequence(first: next, next: { $0?.next }).lazy
                .compactMap({ $0 as? UIViewController }).first else { return }
            commands = [
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(UIViewController.escapeKeyCommandPressed(_:))),
                UIKeyCommand(input: ".", modifierFlags: .command, action: #selector(UIViewController.escapeKeyCommandPressed(_:))),
            ]
            for command in commands {
                command.wantsPriorityOverSystemBehavior = true
                owner.addKeyCommand(command)
            }
            controller = owner
            EscapeKeyRegistry.actions[ObjectIdentifier(owner), default: []].append(self)
        }

        func uninstall() {
            guard let owner = controller else { return }
            for command in commands { owner.removeKeyCommand(command) }
            commands = []
            EscapeKeyRegistry.actions[ObjectIdentifier(owner)]?.removeAll { $0 === self }
            controller = nil
        }
    }
}

@MainActor
private enum EscapeKeyRegistry {
    /// The anchors on each view controller, the latest last: Esc goes to the one shown last.
    static var actions: [ObjectIdentifier: [EscapeKeyCommand.Anchor]] = [:]
}

extension UIViewController {
    /// UIKit sends the command to the first view controller up the responder chain, which may be
    /// a child of the one holding it.
    @objc fileprivate func escapeKeyCommandPressed(_ command: UIKeyCommand) {
        let anchor = sequence(first: self as UIResponder, next: { $0.next }).lazy
            .compactMap { EscapeKeyRegistry.actions[ObjectIdentifier($0)]?.last }.first
        anchor?.action?()
    }
}
#endif
