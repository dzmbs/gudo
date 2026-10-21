#if os(iOS)
import DesignSystem
import SwiftUI
import UIKit

/// A workflow argument field on iPad and iPhone: a plain `UITextField` whose own key commands
/// take ⌘↩ (run), ⇥ / ⇧⇥ (next / previous field) and ⎋ (cancel) ahead of the system's text
/// handling. SwiftUI's `.keyboardShortcut` and `.onKeyPress` never see ⌘↩ while a text field is
/// first responder (UIKit's text input claims it, as `ComposerTextView` found).
struct WorkflowField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let isFocused: Bool
    var onFocus: () -> Void
    var onSubmit: () -> Void
    var onRun: () -> Void
    var onMove: (Int) -> Void
    var onCancel: () -> Void

    func makeUIView(context: Context) -> KeyField {
        let field = KeyField()
        field.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: KeyField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.placeholder = placeholder
        field.onRun = onRun
        field.onMove = onMove
        field.onCancel = onCancel
        // Only when the form asks for this field anew (⇥, appearing): every other update would
        // take the keyboard back from the pane the command was just typed into.
        let requested = isFocused && !context.coordinator.wasFocused
        context.coordinator.wasFocused = isFocused
        if requested, !field.isFirstResponder { Self.focus(field, coordinator: context.coordinator, tries: 20) }
    }

    /// Makes `field` first responder once it is in a window (a field appearing with its panel is
    /// not yet), as long as the form still wants it.
    private static func focus(_ field: KeyField, coordinator: Coordinator, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak field] in
            guard let field, coordinator.parent.isFocused, !field.isFirstResponder else { return }
            if field.window == nil {
                if tries > 0 { focus(field, coordinator: coordinator, tries: tries - 1) }
                return
            }
            _ = field.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ field: KeyField, coordinator: Coordinator) {
        coordinator.wasFocused = false
        if field.isFirstResponder { _ = field.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: WorkflowField
        /// The form wanted this field at the last update.
        var wasFocused = false

        init(_ parent: WorkflowField) {
            self.parent = parent
        }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocus()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }

    final class KeyField: UITextField {
        var onRun: (() -> Void)?
        var onMove: ((Int) -> Void)?
        var onCancel: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            let run = UIKeyCommand(title: "Run", action: #selector(runCommand), input: "\r", modifierFlags: .command)
            let next = UIKeyCommand(title: "Next Argument", action: #selector(nextField), input: "\t")
            let previous = UIKeyCommand(title: "Previous Argument", action: #selector(previousField), input: "\t", modifierFlags: .shift)
            let cancel = UIKeyCommand(title: "Cancel", action: #selector(cancel), input: UIKeyCommand.inputEscape)
            for command in [run, next, previous, cancel] { command.wantsPriorityOverSystemBehavior = true }
            return [run, next, previous, cancel] + (super.keyCommands ?? [])
        }

        @objc private func runCommand() { onRun?() }
        @objc private func nextField() { onMove?(1) }
        @objc private func previousField() { onMove?(-1) }
        @objc private func cancel() { onCancel?() }
    }
}
#endif
