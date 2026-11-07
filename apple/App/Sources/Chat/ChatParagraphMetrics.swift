#if os(iOS)
import CoreText
import DesignSystem
import SwiftUI

/// Only unstyled ASCII that fits one or two native lines skips the SwiftUI sizing graph.
@MainActor
final class ChatParagraphMetrics {
    private enum Lines: Hashable { case one, two }

    private struct Key: Hashable {
        let lines: Lines
        let font: Font.Resolved
        let scale: CGFloat
        let rightToLeft: Bool
        let locale: String
    }

    private let heights = BoundedLRU<Key, CGFloat>(capacity: ChatCacheLimits.paragraphProfiles,
                                                  byteLimit: ChatCacheLimits.bytes)

    func height(for row: ChatRow, width: CGFloat, environment: EnvironmentValues,
                measure: (ChatRow) -> CGFloat?) -> CGFloat? {
        guard environment.textCase == nil, environment.lineHeight == nil,
              case .markdown(let block) = row.content, block.kind == .paragraph,
              block.text.runs.allSatisfy({ $0.attributes == AttributeContainer() }) else { return nil }
        let text = String(block.text.characters)
        guard !text.isEmpty, text.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        let font = DS.Font.prose.resolve(in: environment.fontResolutionContext)
        let available = width - 2 * DS.Space.xl
        guard available > 0, let lines = lineCount(text, font: font.ctFont, width: available) else { return nil }
        let key = Key(lines: lines, font: font, scale: environment.displayScale,
                      rightToLeft: environment.layoutDirection == .rightToLeft, locale: environment.locale.identifier)
        if let height = heights.value(for: key) { return height }
        // Calibrate through the SAME row and environment, not guessed UIFont/line-height equivalents.
        let sampleText = lines == .one ? "M" : "M\nM"
        let sample = ChatMarkdownBlock(kind: .paragraph, source: sampleText, text: AttributedString(sampleText))
        let sampleRow = ChatRow(id: row.id, revision: row.revision, turn: row.turn, content: .markdown(sample))
        guard let height = measure(sampleRow), height.isFinite, height > 0 else { return nil }
        heights.insert(height, for: key, cost: LRUCost(bytes: 2 * (MemoryLayout<Key>.stride + key.locale.utf8.count)))
        return height
    }

    private func lineCount(_ text: String, font: CTFont, width: CGFloat) -> Lines? {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]) as CFAttributedString
        let line = CTLineCreateWithAttributedString(attributed)
        if CTLineGetTypographicBounds(line, nil, nil, nil) < width { return .one }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        // Only admitted ASCII reaches here, so Core Text's UTF-16 offsets equal UTF-8 byte offsets.
        let first = CTTypesetterSuggestLineBreak(typesetter, 0, Double(width))
        guard first > 0, first < text.utf8.count else { return nil }
        let second = CTTypesetterSuggestLineBreak(typesetter, first, Double(width))
        return first + second == text.utf8.count ? .two : nil
    }

    func clear() { heights.removeAll() }
}
#endif
