#if os(iOS)
import UIKit

/// A multi-line text view above the key row for writing to agents. Return inserts a newline; the
/// Send button or ⌘↩ submits. It is prose, so autocorrect and dictation stay on, unlike the terminal.
final class ComposerView: UIView, UITextViewDelegate {
    /// The composer clears itself after calling this.
    var onSubmit: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    let textView = ComposerTextView()
    private let sendButton = UIButton()
    private let style: KeyBarStyle
    private var heightConstraint: NSLayoutConstraint!

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            updateHeight()
        }
    }

    init(style: KeyBarStyle) {
        self.style = style
        super.init(frame: .zero)

        textView.font = style.composerFont
        textView.textColor = style.composerTextColor
        textView.backgroundColor = style.composerBackground
        textView.layer.cornerRadius = style.composerCornerRadius
        textView.textContainerInset = style.composerInsets
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.keyboardType = .default
        textView.returnKeyType = .default
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityIdentifier = "keybar-composer"
        textView.accessibilityLabel = "Composer"
        textView.onSubmit = { [weak self] in self?.submit() }

        sendButton.configuration = style.button(.init(title: nil, symbol: "arrow.up", active: true))
        sendButton.accessibilityIdentifier = "keybar-composer-send"
        sendButton.accessibilityLabel = "Send"
        sendButton.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)

        for view in [textView, sendButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = textView.heightAnchor.constraint(equalToConstant: lineHeight(lines: 1))
        NSLayoutConstraint.activate([
            heightConstraint,
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.horizontalInset),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            sendButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: style.spacing),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -style.horizontalInset),
            sendButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: style.minimumButtonWidth),
            sendButton.heightAnchor.constraint(equalToConstant: lineHeight(lines: 1)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func lineHeight(lines: Int) -> CGFloat {
        (style.composerFont.lineHeight * CGFloat(lines) + style.composerInsets.top + style.composerInsets.bottom).rounded(.up)
    }

    func submit() {
        let text = textView.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSubmit?(text)
        self.text = ""
        onTextChange?("")
    }

    func textViewDidChange(_ textView: UITextView) {
        updateHeight()
        onTextChange?(textView.text)
    }

    private func updateHeight() {
        let width = textView.bounds.width > 0 ? textView.bounds.width : 300
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, lineHeight(lines: 1)), lineHeight(lines: style.composerMaxLines))
        textView.isScrollEnabled = fitting > height
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        onHeightChange?()
    }
}

/// Adds ⌘↩ (submit) to the text view for hardware keyboards; plain Return stays a newline.
final class ComposerTextView: UITextView {
    var onSubmit: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: "Send", action: #selector(submitCommand), input: "\r", modifierFlags: .command)
        send.discoverabilityTitle = "Send to Pane"
        send.wantsPriorityOverSystemBehavior = true
        return [send] + (super.keyCommands ?? [])
    }

    @objc private func submitCommand() {
        onSubmit?()
    }
}
#endif
