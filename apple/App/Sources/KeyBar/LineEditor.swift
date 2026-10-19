#if os(iOS)
import HostKit
import SwiftUI
import UIKit
import UnnamedCore

/// §2.4–2.6). While the daemon reports the pane at a prompt, typing goes into a native text field
/// (caret, loupe, selection, dictation, Scribble for free) and Return submits the whole line in
/// one atomic write. Outside a prompt (a command runs, vim, htop) it hides and keys go straight
/// to the terminal again.
///
/// The smart row shows host completions for the token at the caret: tap inserts, a vertical flick
/// inserts and runs. For agents the decision strip turns a blocked tool call's options into big
/// buttons.
@MainActor
final class LineEditorController: NSObject, UITextFieldDelegate {
    /// Whether the editor may take over at prompts (the profile menu's "Line Editor").
    static let enabledKey = "keyBar.lineEditor"
    /// Off unless turned on: the terminal takes the typing. `bool(forKey:)` also reads a launch
    /// argument (`-keyBar.lineEditor YES`), which arrives as a string.
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    let editorRow = UIView()
    let smartRow = UIScrollView()
    let decisionStrip = UIStackView()
    let field = ShortcutTextField()

    /// The terminal the line belongs to (keys fall back to it).
    weak var terminal: UIResponder?
    /// Asked to relayout the bar when rows appear or disappear.
    var onLayoutChange: (() -> Void)?
    /// Whether the bar's profile is a shell (only shells get the line editor).
    var shellProfile = true {
        didSet { if shellProfile != oldValue { refresh() } }
    }
    var agentProfile = false {
        didSet { if agentProfile != oldValue { refreshBlocked() } }
    }

    private var assist: (any LineAssist)?
    private var prompt: PromptState?
    /// The prompt the user left the editor at with esc: direct mode until the next prompt.
    private var directAt: UInt64?
    private var completionTask: Task<Void, Never>?
    private var blockedTask: Task<Void, Never>?
    private let chipStack = UIStackView()
    private let runButton = UIButton()
    private let message = UILabel()
    private let style: KeyBarStyle

    init(style: KeyBarStyle) {
        self.style = style
        super.init()
        configureField()
        configureSmartRow()
        configureDecisionStrip()
        refresh()
    }

    /// Whether the editor owns typing right now.
    var isActive: Bool { !editorRow.isHidden }

    /// The pane was focused (tapped): typing belongs to the editor while it shows.
    func paneFocused() {
        guard isActive, !field.isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in self?.field.becomeFirstResponder() }
    }

    // MARK: Pane

    /// Follows a new pane: stops watching the old one, watches the new one.
    func attach(_ assist: (any LineAssist)?) {
        guard assist !== self.assist else { return }
        let old = self.assist
        self.assist = assist
        prompt = nil
        directAt = nil
        field.text = ""
        refresh()
        if let old { Task { _ = try? await old.watchPrompt(false, onState: { _ in }) } }
        guard let assist else { return }
        Task { @MainActor [weak self] in
            let state = try? await assist.watchPrompt(true) { [weak self] state in
                Task { @MainActor in self?.received(state, from: assist) }
            }
            if let state { self?.received(state, from: assist) }
        }
        refreshBlocked()
    }

    private func received(_ state: PromptState, from source: any LineAssist) {
        guard source === assist else { return }
        let previous = prompt
        prompt = state
        if case .atPrompt(let input) = state.phase {
            // A fresh prompt: prefill from what the shell already holds, when the reading is sure.
            if previous?.promptId != state.promptId {
                directAt = nil
                field.text = input.confident ? input.text : ""
                message.isHidden = true
                updateCompletions()
            }
        }
        refresh()
    }

    /// Shows or hides the editor for the current prompt state.
    private func refresh() {
        var show = false
        if Self.enabled, shellProfile, let prompt, case .atPrompt = prompt.phase, directAt != prompt.promptId {
            show = true
        }
        let changed = editorRow.isHidden == show
        editorRow.isHidden = !show
        smartRow.isHidden = !show
        if changed {
            if show {
                // Typing continues in the editor if it was going to the terminal.
                if terminal?.isFirstResponder == true { field.becomeFirstResponder() }
            } else if field.isFirstResponder {
                terminal?.becomeFirstResponder()
            }
            onLayoutChange?()
        }
    }

    // MARK: Editing

    private func configureField() {
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        field.textColor = .label
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .never
        field.delegate = self
        field.accessibilityIdentifier = "keybar-line"
        field.accessibilityLabel = "Command line"
        field.addAction(UIAction { [weak self] _ in self?.updateCompletions() }, for: .editingChanged)
        field.backgroundColor = style.composerBackground
        field.layer.cornerRadius = style.composerCornerRadius
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        field.leftViewMode = .always

        runButton.configuration = style.button(.init(title: nil, symbol: "return", active: true))
        runButton.accessibilityIdentifier = "keybar-line-run"
        runButton.accessibilityLabel = "Run"
        runButton.addAction(UIAction { [weak self] _ in self?.submit(run: true) }, for: .touchUpInside)

        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = .systemOrange
        message.isHidden = true

        let stack = UIStackView(arrangedSubviews: [field, runButton])
        stack.axis = .horizontal
        stack.spacing = style.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        editorRow.addSubview(stack)
        editorRow.isHidden = true
        NSLayoutConstraint.activate([
            editorRow.heightAnchor.constraint(equalToConstant: style.buttonHeight + 10),
            stack.leadingAnchor.constraint(equalTo: editorRow.leadingAnchor, constant: style.horizontalInset),
            stack.trailingAnchor.constraint(equalTo: editorRow.trailingAnchor, constant: -style.horizontalInset),
            stack.centerYAnchor.constraint(equalTo: editorRow.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: style.buttonHeight),
            runButton.widthAnchor.constraint(equalToConstant: style.spineKeyWidth + 8),
        ])
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit(run: true)
        return false
    }

    /// Hands the draft to the daemon: one write that clears the shell's line, pastes the text and
    /// (with `run`) presses Return. A busy shell keeps the draft and says so.
    func submit(run: Bool) {
        guard let assist, let prompt else { return }
        let text = field.text ?? ""
        Task { [weak self] in
            do {
                try await assist.submitLine(promptId: prompt.promptId, text: text, run: run)
                guard let self else { return }
                if run { field.text = "" }
                message.isHidden = true
            } catch AssistError.NotAtPrompt {
                self?.show(message: "The shell is busy. Kept your line.")
            } catch {
                self?.show(message: Self.words(for: error))
            }
        }
    }

    /// Esc: the draft goes to the shell's own line (no Return) and typing drops to the terminal
    /// until the next prompt.
    func leaveToShell() {
        guard isActive, let prompt else { return }
        submit(run: false)
        directAt = prompt.promptId
        refresh()
    }

    /// A wing key's character goes into the draft at the caret.
    func insert(_ text: String) {
        field.insertText(text)
        updateCompletions()
    }

    /// ^C in the editor: clears the draft; with an empty draft the terminal gets it.
    func interrupt() -> Bool {
        guard isActive, let text = field.text, !text.isEmpty else { return false }
        field.text = ""
        updateCompletions()
        return true
    }

    /// Joystick ←/→ move the caret by a character inside the editor.
    func moveCaret(by offset: Int) {
        guard let range = field.selectedTextRange,
              let position = field.position(from: range.start, offset: offset)
        else { return }
        field.selectedTextRange = field.textRange(from: position, to: position)
    }

    /// Tab: completes the token at the caret when exactly one candidate fits; otherwise the
    /// smart row already shows them.
    func complete() {
        guard let first = chipStack.arrangedSubviews.first as? ChipButton else { return }
        if chipStack.arrangedSubviews.count == 1 { apply(first.completion, run: false) }
    }

    /// What went wrong, in words: never a type name. The draft always stays in the field.
    static func words(for error: any Error) -> String {
        switch error as? AssistError {
        case .Denied(let message)?: "Not allowed: \(message). Kept your line."
        case .UnknownPane?: "This pane is gone on the host. Kept your line."
        case .NotAtPrompt?: "The shell is busy. Kept your line."
        case .Invalid(let message)?, .NotFound(let message)?, .Failed(let message)?:
            "Couldn't send (\(message)). Kept your line."
        case nil: "Couldn't send: the host didn't answer. Kept your line."
        default: "Couldn't send. Kept your line."
        }
    }

    private func show(message text: String) {
        message.text = text
        message.isHidden = false
    }

    // MARK: Smart row

    private func configureSmartRow() {
        chipStack.axis = .horizontal
        chipStack.spacing = style.spacing
        chipStack.alignment = .center
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        smartRow.showsHorizontalScrollIndicator = false
        smartRow.alwaysBounceHorizontal = true
        smartRow.isHidden = true
        smartRow.accessibilityIdentifier = "keybar-smart-row"
        smartRow.addSubview(chipStack)
        message.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            smartRow.heightAnchor.constraint(equalToConstant: style.compactRowHeight + 8),
            chipStack.leadingAnchor.constraint(equalTo: smartRow.contentLayoutGuide.leadingAnchor, constant: style.horizontalInset),
            chipStack.trailingAnchor.constraint(equalTo: smartRow.contentLayoutGuide.trailingAnchor, constant: -style.horizontalInset),
            chipStack.centerYAnchor.constraint(equalTo: smartRow.frameLayoutGuide.centerYAnchor),
            chipStack.heightAnchor.constraint(equalToConstant: style.compactButtonHeight + 4),
        ])
        chipStack.addArrangedSubview(message)
    }

    /// Asks the host for candidates for the token at the caret; a newer keystroke cancels it.
    private func updateCompletions() {
        completionTask?.cancel()
        guard let assist, isActive || prompt != nil else { return }
        let line = field.text ?? ""
        let cursor = field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) } ?? line.count
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled,
                  let result = try? await assist.complete(line: line, cursor: UInt32(line.unicodeScalars.prefix(cursor).count)),
                  !Task.isCancelled, let self, (field.text ?? "") == line
            else { return }
            showChips(result.items)
        }
    }

    private func showChips(_ items: [Completion]) {
        chipStack.arrangedSubviews.filter { $0 !== message }.forEach { $0.removeFromSuperview() }
        for (index, item) in items.prefix(12).enumerated() {
            let chip = ChipButton(completion: item, style: style)
            chip.accessibilityIdentifier = "keybar-chip-\(index)"
            chip.onPick = { [weak self] run in self?.apply(item, run: run) }
            chipStack.addArrangedSubview(chip)
        }
        smartRow.contentOffset = .zero
    }

    /// Inserts a candidate: a history line replaces the whole draft, anything else replaces the
    /// token at the caret.
    private func apply(_ completion: Completion, run: Bool) {
        let line = field.text ?? ""
        if case .history = completion.kind {
            field.text = completion.text
        } else {
            let caret = field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.start) } ?? line.count
            let chars = Array(line)
            var start = min(caret, chars.count)
            while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
            let separator = completion.text.hasSuffix("/") ? "" : " "
            let replaced = String(chars[..<start]) + completion.text + separator
            field.text = replaced + String(chars[min(caret, chars.count)...])
            if let position = field.position(from: field.beginningOfDocument, offset: replaced.count) {
                field.selectedTextRange = field.textRange(from: position, to: position)
            }
        }
        if run { submit(run: true) } else { updateCompletions() }
    }

    // MARK: Decision strip

    private func configureDecisionStrip() {
        decisionStrip.axis = .horizontal
        decisionStrip.spacing = style.spacing
        decisionStrip.distribution = .fillEqually
        decisionStrip.isLayoutMarginsRelativeArrangement = true
        decisionStrip.directionalLayoutMargins = .init(top: 4, leading: style.horizontalInset, bottom: 4, trailing: style.horizontalInset)
        decisionStrip.isHidden = true
        decisionStrip.accessibilityIdentifier = "keybar-decisions"
        decisionStrip.heightAnchor.constraint(equalToConstant: 52).isActive = true
    }

    /// Fetches the blocked agent's options (called when the pane's title or state changes; agents
    /// retitle their terminal when they block).
    func refreshBlocked() {
        blockedTask?.cancel()
        guard agentProfile, let assist else {
            setDecisions(nil)
            return
        }
        blockedTask = Task { [weak self] in
            let prompt = try? await assist.blockedOptions()
            guard !Task.isCancelled else { return }
            self?.setDecisions(prompt)
        }
    }

    private func setDecisions(_ prompt: BlockedPrompt?) {
        decisionStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let options = prompt?.options ?? []
        for (index, option) in options.prefix(4).enumerated() {
            let button = UIButton(configuration: style.button(.init(title: option.label, symbol: nil, active: index == 0)))
            button.accessibilityIdentifier = "keybar-decision-\(index)"
            button.addAction(UIAction { [weak self] _ in self?.decide(prompt!, index: index) }, for: .touchUpInside)
            decisionStrip.addArrangedSubview(button)
        }
        let show = !options.isEmpty
        if decisionStrip.isHidden == show {
            decisionStrip.isHidden = !show
            onLayoutChange?()
        }
    }

    private func decide(_ prompt: BlockedPrompt, index: Int) {
        guard let assist else { return }
        let option = prompt.options[index]
        if let request = prompt.requestId, let id = option.optionId {
            assist.decide(requestId: request, optionId: id)
        } else {
            Task { try? await assist.answerBlocked(index: UInt32(index), label: option.label) }
        }
        setDecisions(nil)
    }
}

/// A smart-row chip: tap inserts, a vertical flick inserts and runs.
private final class ChipButton: UIButton {
    let completion: Completion
    var onPick: ((_ run: Bool) -> Void)?
    private var start: CGPoint = .zero

    init(completion: Completion, style: KeyBarStyle) {
        self.completion = completion
        super.init(frame: .zero)
        let symbol: String? = switch completion.kind {
        case .history: "clock.arrow.circlepath"
        case .dir: "folder"
        case .path: "doc"
        case .gitRef: "arrow.triangle.branch"
        default: nil
        }
        configuration = style.button(.init(title: completion.display, symbol: symbol, active: false))
        accessibilityLabel = completion.display
        accessibilityHint = "Flick to insert and run"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        start = touch.location(in: self)
        return super.beginTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        guard let touch else { return }
        let point = touch.location(in: self)
        let flicked = abs(point.y - start.y) >= 12
        if flicked || bounds.contains(point) { onPick?(flicked) }
    }
}

/// The line editor's field. It lives in the keyboard's own window, outside the app's menu
/// commands, so it answers the workspace shortcuts itself (⌘T, ⌘D, ⌘W, tabs, panes): otherwise
/// every ⌘ shortcut was dead while it held the keyboard.
final class ShortcutTextField: UITextField {
    private static let actions = WorkspaceAction.allShortcutActions

    override var keyCommands: [UIKeyCommand]? {
        Self.actions.enumerated().map { index, action in
            let command = UIKeyCommand(title: action.title, action: #selector(performShortcut(_:)), input: action.shortcut.key.uiKeyInput,
                                       modifierFlags: action.shortcut.modifiers.uiKeyModifierFlags, propertyList: index)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func performShortcut(_ command: UIKeyCommand) {
        guard let index = command.propertyList as? Int, Self.actions.indices.contains(index),
              let workspace = ActiveWindow.workspace else { return }
        Self.actions[index].perform(on: workspace, window: ActiveWindow.model(for: workspace))
    }
}
#endif
