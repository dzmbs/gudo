import DesignSystem
import DrawingKit
import Observation
import SwiftUI
import TerminalRenderer
#if os(iOS)
import UIKit
#endif

/// Write mode's text path, without UI: recognised handwriting (and anything typed while
/// writing) collects in a draft shown at the prompt as marked text; nothing reaches the shell
/// until `commit` (Return or Send), which types it as one line and presses Return.
@MainActor
final class WriteController {
    private(set) var draft = HandwritingDraft()
    /// Shows (or clears, nil) the preview at the prompt.
    let preview: (String?) -> Void
    /// Types a committed line into the pane and submits it.
    let send: (String) -> Void

    init(preview: @escaping (String?) -> Void, send: @escaping (String) -> Void) {
        self.preview = preview
        self.send = send
    }

    var isEmpty: Bool { draft.isEmpty }

    /// The field's text after an edit (Scribble insert, strike-through delete, typing).
    func update(_ text: String) {
        draft.update(text)
        preview(draft.isEmpty ? nil : draft.preview)
    }

    func clear() {
        draft.clear()
        preview(nil)
    }

    /// Sends the draft; false (and nothing sent) when it is empty.
    @discardableResult
    func commit() -> Bool {
        guard let line = draft.commit() else { return false }
        preview(nil)
        send(line)
        return true
    }

    /// Leaves without sending anything.
    func cancel() {
        draft.clear()
        preview(nil)
    }
}

/// Write mode's bar (bottom of the pane, where the draw toolbar sits).
@Observable
final class WriteModel {
    var isEmpty = true
    @ObservationIgnored var onClear: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onSend: () -> Void = {}
}

struct WriteToolbar: View {
    @Bindable var model: WriteModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "pencil.and.scribble")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .accessibilityHidden(true)
                Text(model.isEmpty ? "Write anywhere · it appears at the prompt" : "Return sends")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !model.isEmpty {
                    Button("Clear") { model.onClear() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("write.clear")
                }
                Button("Cancel") { model.onCancel() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("write.cancel")
                Button { model.onSend() } label: { Label("Send", systemImage: "return") }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isEmpty)
                    .help("Type it at the prompt and press Return")
                    .accessibilityIdentifier("write.send")
            }
            .padding(6)
            .floatingCapsule()
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("write.toolbar")
    }
}

#if os(iOS)
/// Write mode over a terminal pane (iPad): write with Apple Pencil anywhere over the pane;
/// Scribble (`UIIndirectScribbleInteraction`) turns it into text in a hidden field, which shows
/// live at the terminal prompt as marked text (the renderer's IME preview). Return or Send types
/// it into the shell; Cancel drops it. The terminal itself never takes Scribble
/// (`TerminalView.allowsHandwriting` stays off), so nothing reaches the shell unseen.
@MainActor
final class WriteOverlay: UIView, UIIndirectScribbleInteractionDelegate, UITextViewDelegate {
    typealias ElementIdentifier = String

    private unowned let drawing: PaneDrawing
    private weak var terminal: TerminalView?
    private(set) var controller: WriteController!
    private let field = HandwritingField()
    private let model = WriteModel()
    private let toolbar: UIHostingController<WriteToolbar>
    private let previewMarker = UIView()
    private var terminalHadKeyboard = false
    private var closed = false
    private static let element = "prompt"

    init(drawing: PaneDrawing, terminal: TerminalView) {
        self.drawing = drawing
        self.terminal = terminal
        toolbar = UIHostingController(rootView: WriteToolbar(model: model))
        super.init(frame: terminal.bounds)
        controller = WriteController(
            preview: { [weak self] text in self?.showPreview(text) },
            send: { [weak terminal] line in terminal?.sendComposedText(line, submit: true) })
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        accessibilityIdentifier = "write.overlay"

        field.delegate = self
        field.frame = bounds
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        field.onEscape = { [weak self] in self?.cancel() }
        addSubview(field)

        previewMarker.isUserInteractionEnabled = false
        previewMarker.isAccessibilityElement = true
        previewMarker.accessibilityIdentifier = "write.preview"
        previewMarker.accessibilityLabel = "Handwriting at the prompt"
        addSubview(previewMarker)

        addInteraction(UIIndirectScribbleInteraction(delegate: self))

        model.onClear = { [weak self] in
            self?.field.text = ""
            self?.textViewDidChange(self!.field)
        }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onSend = { [weak self] in self?.send() }
        toolbar.view.backgroundColor = .clear
        toolbar.sizingOptions = [.intrinsicContentSize]
        toolbar.overrideUserInterfaceStyle = drawing.isDarkTheme ? .dark : .light
        addSubview(toolbar.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { controller.isEmpty }

    func start() {
        terminalHadKeyboard = terminal?.isFirstResponder ?? false
        // Typing on a hardware keyboard while writing edits the same draft.
        field.becomeFirstResponder()
        CanvasWebView.log.info("write: on pane \(self.drawing.paneId)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = toolbar.view.intrinsicContentSize
        let bottom = bounds.height - safeAreaInsets.bottom - 12
        toolbar.view.frame = CGRect(x: (bounds.width - size.width) / 2, y: bottom - size.height, width: size.width, height: size.height)
        placePreviewMarker()
    }

    // MARK: Draft

    private func showPreview(_ text: String?) {
        terminal?.surface.preedit = text.map { TerminalSurface.Preedit(text: $0) }
        previewMarker.accessibilityValue = text ?? ""
        model.isEmpty = text == nil
        placePreviewMarker()
        setNeedsLayout()
    }

    private func placePreviewMarker() {
        guard let terminal, let cursor = terminal.surface.cursorRect else { return }
        let cells = max(1, (previewMarker.accessibilityValue ?? "").count)
        previewMarker.frame = convert(CGRect(x: cursor.minX, y: cursor.minY, width: cursor.width * CGFloat(cells), height: cursor.height), from: terminal)
    }

    func textViewDidChange(_ textView: UITextView) {
        controller.update(textView.text ?? "")
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Return sends (Scribble never inserts a bare newline; the keyboard's Return does).
        guard text == "\n" else { return true }
        send()
        return false
    }

    private func send() {
        let line = controller.draft.preview
        guard controller.commit() else { return }
        CanvasWebView.log.info("write: sent \(line.count) character(s) to pane \(self.drawing.paneId)")
        close()
    }

    func cancel() {
        controller.cancel()
        CanvasWebView.log.info("write: cancelled")
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        terminal?.surface.preedit = nil
        field.resignFirstResponder()
        drawing.writerClosed()
        if terminalHadKeyboard { _ = terminal?.becomeFirstResponder() }
    }

    // MARK: Scribble

    func indirectScribbleInteraction(
        _ interaction: any UIInteraction, requestElementsIn rect: CGRect, completion: @escaping ([ElementIdentifier]) -> Void
    ) {
        completion([Self.element])
    }

    func indirectScribbleInteraction(_ interaction: any UIInteraction, isElementFocused elementIdentifier: ElementIdentifier) -> Bool {
        field.isFirstResponder
    }

    func indirectScribbleInteraction(_ interaction: any UIInteraction, frameForElement elementIdentifier: ElementIdentifier) -> CGRect {
        bounds
    }

    func indirectScribbleInteraction(
        _ interaction: any UIInteraction, focusElementIfNeeded elementIdentifier: ElementIdentifier, referencePoint focusReferencePoint: CGPoint,
        completion: @escaping ((any UIResponder & UITextInput)?) -> Void
    ) {
        if !field.isFirstResponder { field.becomeFirstResponder() }
        completion(field)
    }

    func indirectScribbleInteraction(_ interaction: any UIInteraction, willBeginWritingInElement elementIdentifier: ElementIdentifier) {
        CanvasWebView.log.info("write: Scribble began")
    }

    func indirectScribbleInteraction(_ interaction: any UIInteraction, didFinishWritingInElement elementIdentifier: ElementIdentifier) {
        CanvasWebView.log.info("write: Scribble finished (\(self.controller.draft.preview.count) character(s) in the draft)")
    }
}

/// The hidden field Scribble writes into: no visible text, caret or software keyboard (the
/// preview is at the prompt); Escape cancels.
final class HandwritingField: UITextView {
    var onEscape: (() -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        isUserInteractionEnabled = false
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        inlinePredictionType = .no
        inputView = UIView(frame: .zero)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        accessibilityIdentifier = "write.field"
        accessibilityLabel = "Handwriting"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
    }

    @objc private func escape() { onEscape?() }
}
#endif
