import DesignSystem
import SwiftUI

/// Inline code reads as a literal: SF Mono, a step under the prose around it, on the raised fill.
/// Code stays on one line where it fits: a short span never breaks, a long one only at its spaces.
/// Its fill is drawn per line (`ChatCodeBackground`): one rounded box from its first to its last
/// word on that line, so a line never starts or ends on filled space.
nonisolated enum ChatInlineCode {
    private static let wordJoiner: Character = "\u{2060}"
    private static let noBreakSpace: Character = "\u{00A0}"
    /// Fits a line of the narrowest phone column at the largest standard text size.
    private static let unbrokenLength = 24
    static let boxOutset = DS.Space.xxs

    /// The text as it lays out: code in SF Mono, its words joined so they break only at spaces.
    static func joined(_ text: AttributedString) -> AttributedString {
        pieces(of: text).reduce(into: AttributedString()) { joined, piece in joined.append(piece.text) }
    }

    /// The text to show, its code tagged for `ChatCodeBackground`.
    static func text(_ text: AttributedString) -> Text {
        guard hasCode(text) else { return Text(text) }
        return pieces(of: text).reduce(Text(verbatim: "")) { combined, piece in
            let segment = piece.code.map { Text(piece.text).customAttribute($0) } ?? Text(piece.text)
            return Text("\(combined)\(segment)")
        }
    }

    /// One box per code span per line, from its first word's leading edge to its last word's
    /// trailing edge on that line.
    static func boxes(in layout: Text.Layout) -> [CGRect] {
        var boxes: [CGRect] = []
        for line in layout {
            var current: (span: Int, rect: CGRect)?
            for run in line {
                guard let code = run[ChatCodeSpan.self] else {
                    if let box = current { boxes.append(box.rect) }
                    current = nil
                    continue
                }
                if code.isSpace { continue }
                let rect = run.typographicBounds.rect
                if let box = current, box.span == code.span {
                    current = (code.span, box.rect.union(rect))
                } else {
                    if let box = current { boxes.append(box.rect) }
                    current = (code.span, rect)
                }
            }
            if let box = current { boxes.append(box.rect) }
        }
        return boxes.map { $0.insetBy(dx: -boxOutset, dy: 0) }
    }

    private struct Piece {
        var text: AttributedString
        var code: ChatCodeSpan?
    }

    static func hasCode(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }
    }

    private static func pieces(of text: AttributedString) -> [Piece] {
        var pieces: [Piece] = []
        var prose = AttributedString()
        var span = 0
        for run in text.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else {
                prose.append(text[run.range])
                continue
            }
            if !prose.characters.isEmpty { pieces.append(Piece(text: prose)); prose = AttributedString() }
            var attributes = run.attributes
            attributes.font = ChatFont.literal
            let characters = Array(text[run.range].characters)
            let keepsWhole = characters.count <= unbrokenLength
            for word in words(of: characters, keepsWhole: keepsWhole) {
                pieces.append(Piece(text: AttributedString(joiningWords(of: word, keepsWhole: keepsWhole), attributes: attributes),
                                    code: ChatCodeSpan(span: span, isSpace: word.allSatisfy { $0 == " " })))
            }
            span += 1
        }
        if !prose.characters.isEmpty { pieces.append(Piece(text: prose)) }
        return pieces
    }

    /// A long span's words and the spaces between them, kept apart so its fill can leave a
    /// space at a line end unfilled; a short span stays one piece.
    private static func words(of characters: [Character], keepsWhole: Bool) -> [[Character]] {
        guard !keepsWhole else { return [characters] }
        var words: [[Character]] = []
        for character in characters {
            if let last = words.last?.last, (last == " ") == (character == " ") {
                words[words.count - 1].append(character)
            } else {
                words.append([character])
            }
        }
        return words
    }

    /// Hyphens, slashes and the like are line-break opportunities in prose; inside a word of
    /// code a break there splits one token across two lines.
    private static func joiningWords(of characters: [Character], keepsWhole: Bool) -> String {
        var joined = ""
        var previous: Character?
        for character in characters {
            if let previous, !previous.isWhitespace, !character.isWhitespace { joined.append(wordJoiner) }
            joined.append(keepsWhole && character == " " ? noBreakSpace : character)
            previous = character
        }
        return joined
    }
}

/// Marks a piece of inline code: which span it belongs to and whether it is the space between two words.
nonisolated struct ChatCodeSpan: TextAttribute {
    let span: Int
    let isSpace: Bool
}

/// Draws inline code's fill behind the text, one rounded box per span per line.
nonisolated struct ChatCodeBackground: TextRenderer {
    let fill: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for box in ChatInlineCode.boxes(in: layout) {
            context.fill(Path(roundedRect: box, cornerRadius: DS.Radius.chip, style: .continuous), with: .color(fill))
        }
        for line in layout { context.draw(line) }
    }
}
/// Text with code draws its fill; text without keeps the system's own text drawing.
struct ChatCodeFill: ViewModifier {
    let fill: Color?

    func body(content: Content) -> some View {
        if let fill { content.textRenderer(ChatCodeBackground(fill: fill)) } else { content }
    }
}
