import SwiftUI

enum InboxKey: CaseIterable {
    case previous, next, approve, approveAll, deny, edit
}

#if os(iOS)
import UIKit

/// The Inbox's keyboard on iPad: a responder that holds the keyboard while the Inbox is on screen
/// and no field is typing. SwiftUI's shortcuts never see plain ↩ and letters on iPadOS (the focus
/// system and text input take them first); key commands on the first responder, with priority over
/// system behaviour, do. A field that takes the keyboard (reply, edited command) simply becomes the
/// first responder instead, and the catcher takes it back when `active` returns.
struct InboxKeyCatcher: UIViewRepresentable {
    var active: Bool
    var handle: (InboxKey) -> Void

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handle = handle
        return view
    }

    func updateUIView(_ view: CatcherView, context: Context) {
        view.handle = handle
        view.active = active
        view.claim()
    }

    final class CatcherView: UIView {
        var handle: (InboxKey) -> Void = { _ in }
        var active = true

        override var canBecomeFirstResponder: Bool { active }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            claim()
        }

        /// Takes the keyboard (from a terminal behind the Inbox, or back from a closed field).
        func claim() {
            guard active, window != nil, !isFirstResponder else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            func command(_ input: String, _ flags: UIKeyModifierFlags = [], _ title: String, _ action: Selector) -> UIKeyCommand {
                let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
            return [
                command(UIKeyCommand.inputUpArrow, [], "Previous", #selector(keyPrevious)),
                command(UIKeyCommand.inputDownArrow, [], "Next", #selector(keyNext)),
                command("\r", [], "Approve or Open", #selector(keyApprove)),
                command("\r", .shift, "Approve All Like This", #selector(keyApproveAll)),
                command(UIKeyCommand.inputEscape, [], "Deny", #selector(keyDeny)),
                command(".", .command, "Deny", #selector(keyDeny)),
                command("e", [], "Edit, Then Approve", #selector(keyEdit)),
            ]
        }

        /// ↩ as a press too, should a focused control's "select" let it through to the responder.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard active, let key = presses.first?.key, key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
                  key.modifierFlags.isDisjoint(with: [.command, .control, .alternate])
            else { return super.pressesBegan(presses, with: event) }
            handle(key.modifierFlags.contains(.shift) ? .approveAll : .approve)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if let key = presses.first?.key, key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter { return }
            super.pressesEnded(presses, with: event)
        }

        @objc private func keyPrevious() { handle(.previous) }
        @objc private func keyNext() { handle(.next) }
        @objc private func keyApprove() { handle(.approve) }
        @objc private func keyApproveAll() { handle(.approveAll) }
        @objc private func keyDeny() { handle(.deny) }
        @objc private func keyEdit() { handle(.edit) }
    }
}
#endif
