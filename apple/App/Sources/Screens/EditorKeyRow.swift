#if os(iOS)
import UIKit
import WebKit

/// The keys VS Code needs that the software keyboard lacks, above it while the workbench has the
/// keyboard on a phone, in place of the browser's form controls.
final class EditorKeyRow: UIInputView {
    private let press: (EditorPhoneLayout.Key) -> Void
    private let dismiss: () -> Void
    private let style = KeyBarStyle.default

    init(press: @escaping (EditorPhoneLayout.Key) -> Void, dismiss: @escaping () -> Void) {
        self.press = press
        self.dismiss = dismiss
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: KeyBarStyle.default.rowHeight + 8), inputViewStyle: .default)
        backgroundColor = .clear
        allowsSelfSizing = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: style.rowHeight + 8)
    }

    private func build() {
        let keys = UIStackView()
        keys.axis = .horizontal
        keys.spacing = style.spacing
        keys.alignment = .center
        keys.translatesAutoresizingMaskIntoConstraints = false
        for key in EditorPhoneLayout.Key.row {
            keys.addArrangedSubview(button(title: key.label, symbol: key.symbol, accessibility: key.accessibilityLabel) { [weak self] in
                self?.press(key)
            })
        }
        keys.addArrangedSubview(UIView())
        keys.addArrangedSubview(button(title: nil, symbol: "keyboard.chevron.compact.down", accessibility: "Hide Keyboard") { [weak self] in
            self?.dismiss()
        })
        addSubview(keys)
        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: style.horizontalInset),
            keys.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -style.horizontalInset),
            keys.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            keys.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    private func button(title: String?, symbol: String?, accessibility: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: style.button(.init(title: title, symbol: symbol, active: false)))
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.accessibilityLabel = accessibility
        button.accessibilityIdentifier = "editor-key-\(accessibility.lowercased().replacingOccurrences(of: " ", with: "-"))"
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: style.buttonHeight),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: style.minimumButtonWidth),
        ])
        return button
    }
}

/// A web view whose keyboard carries `keyRow`.
final class EditorWebView: WKWebView {
    var keyRow: UIView?

    override var inputAccessoryView: UIView? { keyRow ?? super.inputAccessoryView }
}
#endif
