import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where each line of a text starts (UTF-16 offsets), for the numbers beside it.
nonisolated struct LineStarts: Equatable, Sendable {
    let offsets: [Int]

    init(_ text: String) {
        var offsets = [0]
        var position = 0
        for unit in text.utf16 {
            position += 1
            if unit == 0x0A { offsets.append(position) }
        }
        self.offsets = offsets
    }

    var count: Int { offsets.count }

    /// The zero-based line holding a UTF-16 offset.
    func line(at offset: Int) -> Int {
        var low = 0, high = offsets.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func isLineStart(_ offset: Int) -> Bool { offsets[line(at: offset)] == offset }

    /// A zero-based line's characters, without its newline.
    func range(ofLine index: Int, textLength: Int) -> NSRange {
        guard offsets.indices.contains(index) else { return NSRange(location: NSNotFound, length: 0) }
        let end = index + 1 < offsets.count ? offsets[index + 1] - 1 : textLength
        return NSRange(location: offsets[index], length: max(0, end - offsets[index]))
    }
}

/// What a code view shows: the text, the number of its first line and the line to mark.
struct CodeTextContent: Equatable {
    var text: String
    var firstLine = 1
    var markedLine: Int?
}

/// A file's text as the platform's own read-only text view: select with the pointer or a finger,
/// ⌘A selects all of it, and Copy takes plain text. Line numbers sit in a gutter beside the text,
/// never in it.
struct CodeTextView: View {
    let content: CodeTextContent
    @Environment(\.terminalTheme) private var theme
    @Environment(\.chrome) private var chrome

    init(_ text: String, firstLine: Int = 1, markedLine: Int? = nil) {
        content = CodeTextContent(text: text, firstLine: firstLine, markedLine: markedLine)
    }

    var body: some View {
        PlatformCodeView(content: content, colors: CodeTextColors(theme: theme, chrome: chrome))
            .background(theme.background)
    }
}

struct CodeTextColors: Equatable {
    var text: Color
    var background: Color
    var number: Color
    var markedNumber: Color
    var markedLine: Color
    var selection: Color
    var selectedText: Color

    init(theme: TerminalTheme, chrome: ChromePalette) {
        text = theme.foreground
        background = theme.background
        number = chrome.color(.textQuaternary)
        markedNumber = chrome.color(.text)
        markedLine = chrome.color(.accentDim)
        selection = chrome.color(.selection)
        selectedText = chrome.color(.onSelection)
    }
}

/// Shared by the platform views: the gutter's width and which line fragments get a number.
@MainActor
final class CodeGutterLayout {
    private(set) var starts = LineStarts("")
    private(set) var content = CodeTextContent(text: "")

    func update(_ content: CodeTextContent) {
        self.content = content
        starts = LineStarts(content.text)
    }

    var lastNumber: Int { content.firstLine + starts.count - 1 }

    func width(digitWidth: CGFloat) -> CGFloat {
        CGFloat(max(3, String(lastNumber).count)) * digitWidth + DS.Space.l + DS.Space.s
    }

    /// The number shown beside a line fragment starting at `characterIndex`; nil for the second
    /// and later fragments of a wrapped line.
    func number(atCharacter characterIndex: Int) -> Int? {
        guard starts.isLineStart(characterIndex) else { return nil }
        return content.firstLine + starts.line(at: characterIndex)
    }

    /// The marked line's characters, when it is in the text.
    var markedRange: NSRange? {
        guard let marked = content.markedLine else { return nil }
        let range = starts.range(ofLine: marked - content.firstLine, textLength: content.text.utf16.count)
        return range.location == NSNotFound ? nil : range
    }
}

#if os(macOS)
private func codeFont() -> NSFont {
    NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
}

private struct PlatformCodeView: NSViewRepresentable {
    let content: CodeTextContent
    let colors: CodeTextColors

    /// The text system's "no limit": wider than any line, yet finite (it lays glyphs out in floats).
    private static let unbounded: CGFloat = 1e7

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeNSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.textContainerInset = NSSize(width: DS.Space.xs, height: DS.Space.s)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: Self.unbounded, height: Self.unbounded)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: Self.unbounded, height: Self.unbounded)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityIdentifier("code-text")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        let ruler = LineNumberRuler(scrollView: scroll, textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.attach(scroll: scroll, textView: textView, ruler: ruler)
        context.coordinator.update(content, colors: colors)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(content, colors: colors)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let gutter = CodeGutterLayout()
        private weak var scroll: NSScrollView?
        private weak var textView: CodeNSTextView?
        private weak var ruler: LineNumberRuler?
        private var shownContent: CodeTextContent?
        private var shownColors: CodeTextColors?
        private var observer: NSObjectProtocol?

        isolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(scroll: NSScrollView, textView: CodeNSTextView, ruler: LineNumberRuler) {
            self.scroll = scroll
            self.textView = textView
            self.ruler = ruler
            textView.gutter = gutter
            ruler.gutter = gutter
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak ruler] _ in
                MainActor.assumeIsolated { ruler?.needsDisplay = true }
            }
        }

        func update(_ content: CodeTextContent, colors: CodeTextColors) {
            guard let textView, let scroll, let ruler else { return }
            let font = codeFont()
            let isNewText = content.text != shownContent?.text
            if colors != shownColors {
                shownColors = colors
                textView.backgroundColor = NSColor(colors.background)
                textView.markedLineColor = NSColor(colors.markedLine)
                textView.selectedTextAttributes = [
                    .backgroundColor: NSColor(colors.selection), .foregroundColor: NSColor(colors.selectedText),
                ]
                ruler.colors = colors
                scroll.backgroundColor = NSColor(colors.background)
                if !isNewText, let storage = textView.textStorage {
                    storage.addAttribute(.foregroundColor, value: NSColor(colors.text), range: NSRange(location: 0, length: storage.length))
                }
            }
            guard content != shownContent else { return }
            shownContent = content
            gutter.update(content)
            if isNewText {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(colors.text)]
                textView.textStorage?.setAttributedString(NSAttributedString(string: content.text, attributes: attributes))
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            ruler.ruleThickness = gutter.width(digitWidth: font.maximumAdvancement.width)
            textView.needsDisplay = true
            ruler.needsDisplay = true
            Task { @MainActor [weak self] in self?.scrollToMarkedLine() }
        }

        private func scrollToMarkedLine() {
            guard let textView, let scroll, let range = gutter.markedRange, let layout = textView.layoutManager,
                  let container = textView.textContainer else { return }
            // Brings the line in (sizing the text view to reach it), then centres it.
            textView.scrollRangeToVisible(range)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let clip = scroll.contentView
            let highest = max(0, textView.frame.height - clip.bounds.height)
            let y = min(highest, max(0, rect.midY + textView.textContainerInset.height - clip.bounds.height / 2))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }
}

/// The text view: the marked line's band behind the text, across the whole width.
final class CodeNSTextView: NSTextView {
    var gutter: CodeGutterLayout?
    var markedLineColor: NSColor?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let range = gutter?.markedRange, let layout = layoutManager, let container = textContainer, let markedLineColor else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var band = layout.boundingRect(forGlyphRange: glyphs, in: container)
        band.origin.y += textContainerInset.height
        band.origin.x = bounds.minX
        band.size.width = bounds.width
        markedLineColor.setFill()
        band.intersection(rect).fill(using: .sourceOver)
    }
}

/// Line numbers beside the text, drawn for the rows in view only.
final class LineNumberRuler: NSRulerView {
    weak var gutter: CodeGutterLayout?
    var colors: CodeTextColors? {
        didSet { needsDisplay = true }
    }
    private weak var codeView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        codeView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // AppKit hands views dirty rects past their bounds unless they clip: the gutter's fill
        // would cover the text.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let colors { NSColor(colors.background).setFill() }
        bounds.intersection(dirtyRect).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let codeView, let gutter, let colors, let layout = codeView.layoutManager, let container = codeView.textContainer else { return }
        let visible = codeView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let font = NSFont.monospacedDigitSystemFont(ofSize: codeFont().pointSize, weight: .regular)
        let marked = gutter.content.markedLine
        let inset = codeView.textContainerInset.height
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let characterIndex = layout.characterIndexForGlyph(at: glyphRange.location)
            guard let number = gutter.number(atCharacter: characterIndex) else { return }
            let color = NSColor(number == marked ? colors.markedNumber : colors.number)
            let label = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: color])
            let origin = self.convert(NSPoint(x: 0, y: fragment.minY + inset), from: codeView)
            let size = label.size()
            let x = self.ruleThickness - size.width - DS.Space.m
            label.draw(at: NSPoint(x: x, y: origin.y + (fragment.height - size.height) / 2))
        }
        if layout.extraLineFragmentRect.height > 0, gutter.content.text.isEmpty {
            let label = NSAttributedString(string: "\(gutter.content.firstLine)", attributes: [.font: font, .foregroundColor: NSColor(colors.number)])
            let origin = convert(NSPoint(x: 0, y: inset), from: codeView)
            label.draw(at: NSPoint(x: ruleThickness - label.size().width - DS.Space.m, y: origin.y))
        }
    }
}
#else
private func codeFont() -> UIFont {
    let defaultSize = UIFont.preferredFont(forTextStyle: .callout, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    return UIFontMetrics(forTextStyle: .callout).scaledFont(for: .monospacedSystemFont(ofSize: defaultSize, weight: .regular))
}

private struct PlatformCodeView: UIViewRepresentable {
    let content: CodeTextContent
    let colors: CodeTextColors

    func makeUIView(context: Context) -> CodeUITextView {
        let textView = CodeUITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainer.lineFragmentPadding = 0
        textView.layoutManager.allowsNonContiguousLayout = true
        textView.accessibilityIdentifier = "code-text"
        context.coordinator.textView = textView
        context.coordinator.update(content, colors: colors)
        return textView
    }

    func updateUIView(_ textView: CodeUITextView, context: Context) {
        context.coordinator.update(content, colors: colors)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var textView: CodeUITextView?
        private var shownContent: CodeTextContent?
        private var shownColors: CodeTextColors?

        func update(_ content: CodeTextContent, colors: CodeTextColors) {
            guard let textView else { return }
            let font = codeFont()
            let isNewText = content.text != shownContent?.text
            if colors != shownColors {
                shownColors = colors
                textView.colors = colors
                textView.backgroundColor = UIColor(colors.background)
                textView.tintColor = UIColor(colors.selection)
                if !isNewText {
                    let storage = textView.textStorage
                    storage.addAttribute(.foregroundColor, value: UIColor(colors.text), range: NSRange(location: 0, length: storage.length))
                }
            }
            guard content != shownContent else { return }
            shownContent = content
            textView.gutter.update(content)
            if isNewText {
                textView.attributedText = NSAttributedString(
                    string: content.text, attributes: [.font: font, .foregroundColor: UIColor(colors.text)])
            }
            let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
            let gutterWidth = textView.gutter.width(digitWidth: digitWidth)
            textView.textContainerInset = UIEdgeInsets(top: DS.Space.s, left: gutterWidth, bottom: DS.Space.s, right: DS.Space.l)
            textView.setNeedsLayout()
            Task { @MainActor [weak textView] in textView?.scrollToMarkedLine() }
        }
    }
}

/// The text view on touch: lines wrap, numbers stay beside their first row, and the marked
/// line's band sits behind the text.
final class CodeUITextView: UITextView {
    let gutter = CodeGutterLayout()
    var colors: CodeTextColors? {
        didSet {
            numbers.setNeedsDisplay()
            band.backgroundColor = colors.map { UIColor($0.markedLine) }
        }
    }
    private let numbers = LineNumberGutterView()
    private let band = UIView()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        numbers.textView = self
        numbers.isUserInteractionEnabled = false
        numbers.isOpaque = false
        band.isUserInteractionEnabled = false
        band.isHidden = true
        insertSubview(band, at: 0)
        addSubview(numbers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        numbers.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: textContainerInset.left, height: bounds.height)
        numbers.setNeedsDisplay()
        bringSubviewToFront(numbers)
        layoutBand()
    }

    private func layoutBand() {
        guard let rect = markedLineRect else {
            band.isHidden = true
            return
        }
        band.isHidden = false
        band.frame = CGRect(x: 0, y: rect.minY, width: max(bounds.width, contentSize.width), height: rect.height)
        sendSubviewToBack(band)
    }

    /// The marked line in the view's content coordinates.
    private var markedLineRect: CGRect? {
        guard let range = gutter.markedRange else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return rect.offsetBy(dx: 0, dy: textContainerInset.top)
    }

    func scrollToMarkedLine() {
        guard let range = gutter.markedRange else { return }
        layoutManager.ensureLayout(forCharacterRange: range)
        guard let rect = markedLineRect else { return }
        let maxY = max(0, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let y = min(maxY, max(-adjustedContentInset.top, rect.midY - bounds.height / 2))
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
    }
}

private final class LineNumberGutterView: UIView {
    weak var textView: CodeUITextView?

    override func draw(_ rect: CGRect) {
        guard let textView, let colors = textView.colors else { return }
        UIColor(colors.background).setFill()
        UIRectFill(bounds)
        let gutter = textView.gutter
        let layout = textView.layoutManager
        let inset = textView.textContainerInset
        let visible = CGRect(x: 0, y: textView.contentOffset.y - inset.top, width: textView.bounds.width, height: textView.bounds.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: textView.textContainer)
        let font = UIFont.monospacedDigitSystemFont(ofSize: codeFont().pointSize, weight: .regular)
        let marked = gutter.content.markedLine
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let characterIndex = layout.characterIndexForGlyph(at: glyphRange.location)
            guard let number = gutter.number(atCharacter: characterIndex) else { return }
            let color = UIColor(number == marked ? colors.markedNumber : colors.number)
            let label = NSAttributedString(string: "\(number)", attributes: [.font: font, .foregroundColor: color])
            let size = label.size()
            let y = fragment.minY + inset.top - textView.contentOffset.y + (fragment.height - size.height) / 2
            label.draw(at: CGPoint(x: self.bounds.width - size.width - DS.Space.m, y: y))
        }
    }
}
#endif
