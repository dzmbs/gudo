import Foundation

nonisolated public enum RecognitionEvent: Sendable, Equatable {
    /// The words of the segment still being recognized. Replaces the previous volatile text.
    case volatile(String)
    /// A finished segment: appended to the transcript; the volatile text is cleared.
    case finalized(String)
}

nonisolated public struct Transcript: Equatable, Sendable {
    /// Segments the recognizer will not change any more, joined.
    public private(set) var finalized = ""
    public private(set) var volatile = ""

    public init(finalized: String = "", volatile: String = "") {
        self.finalized = Self.normalize(finalized)
        self.volatile = Self.normalize(volatile)
    }

    public var text: String {
        [finalized, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isEmpty: Bool { finalized.isEmpty && volatile.isEmpty }

    public mutating func apply(_ event: RecognitionEvent) {
        switch event {
        case .volatile(let words):
            volatile = Self.normalize(words)
        case .finalized(let words):
            let words = Self.normalize(words)
            finalized = [finalized, words].filter { !$0.isEmpty }.joined(separator: " ")
            volatile = ""
        }
    }

    /// One line: every run of whitespace (newlines included) becomes one space, trimmed. A
    /// transcript never carries a Return, so committing it can never run a command.
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

nonisolated public enum DictationPreview {
    /// The end of `text` that fits in `columns` terminal cells, with a leading "…" when the start
    /// had to go. East Asian wide characters and emoji take two cells. Empty when nothing fits.
    public static func fit(_ text: String, columns: Int) -> String {
        guard columns > 0, !text.isEmpty else { return "" }
        if cells(text) <= columns { return text }
        guard columns > 1 else { return "…" }
        var kept: [Character] = []
        var used = 1  // the ellipsis
        for character in text.reversed() {
            let width = cellWidth(character)
            guard used + width <= columns else { break }
            kept.append(character)
            used += width
        }
        return "…" + String(kept.reversed())
    }

    public static func cells(_ text: String) -> Int {
        text.reduce(0) { $0 + cellWidth($1) }
    }

    /// Two for East Asian wide characters and emoji presentation, else one (as the terminal's
    /// preedit layout counts them).
    public static func cellWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first?.value else { return 1 }
        if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x20000...0x3FFFD,
        ]
        return wide.contains { $0.contains(scalar) } ? 2 : 1
    }
}
