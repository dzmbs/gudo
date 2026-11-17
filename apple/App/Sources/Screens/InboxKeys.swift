import SwiftUI

enum InboxKey: CaseIterable {
    case previous, next, approve, approveAll, deny, edit
}

#if os(iOS)
import UIKit

/// The Inbox's keyboard on iPad: a first responder that holds the keyboard while no field is typing.
// SwiftUI shortcuts never see plain ↩ and letters on iPadOS (focus and text input take them first);
// key commands on the first responder, with priority over system behaviour, do.
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

        // ↩ as a press too, in case a focused control's "select" lets it through to the responder.
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
#elseif os(macOS)
import AppKit

/// The Inbox's keyboard on the Mac, read from each key event: SwiftUI shortcuts answer a plain ↩
/// with the ⇧↩ one, and a field that is typing keeps its keys.
struct InboxKeyCatcher: NSViewRepresentable {
    var active: Bool
    var handle: (InboxKey) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handle = handle
        view.active = active
    }

    final class CatcherView: NSView {
        var handle: (InboxKey) -> Void = { _ in }
        var active = true

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard active, event.type == .keyDown, !isTyping, let key = Self.key(for: event) else {
                return super.performKeyEquivalent(with: event)
            }
            handle(key)
            return true
        }

        /// A text field on screen has the keyboard (a field gone from the window keeps no claim).
        private var isTyping: Bool {
            guard let text = window?.firstResponder as? NSText else { return false }
            return text.window === window && !text.isHiddenOrHasHiddenAncestor
        }

        static func key(for event: NSEvent) -> InboxKey? {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let returnKeys: Set<UInt16> = [36, 76]
            switch (event.keyCode, modifiers) {
            case (126, []): return .previous
            case (125, []): return .next
            case (53, []): return .deny
            case (let code, []) where returnKeys.contains(code): return .approve
            case (let code, .shift) where returnKeys.contains(code): return .approveAll
            default: break
            }
            switch (event.charactersIgnoringModifiers, modifiers) {
            case ("e", []): return .edit
            case (".", .command): return .deny
            default: return nil
            }
        }
    }
}
#endif
