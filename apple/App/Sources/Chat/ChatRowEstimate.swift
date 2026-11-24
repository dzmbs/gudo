import CoreGraphics
import DesignSystem
import HostKit

/// A row's height before it is measured, close enough that the first frame shows whole text.
nonisolated enum ChatRowEstimate {
    /// Body text at the default size: a 22 pt line, and an average glyph about half of 17 pt.
    static let lineHeight: CGFloat = 22
    static let averageCharacterWidth: CGFloat = 8.5

    static func height(for row: ChatRow, rowWidth: CGFloat, scale: CGFloat) -> CGFloat {
        let textWidth = rowWidth - 2 * DS.Space.xl
        switch row.content {
        case .markdown(let block):
            switch block.kind {
            case .code: return (CGFloat(block.code?.visibleLineCount ?? 1) * 20 + 84) * scale
            case .table: return (CGFloat(block.table.count) * 34 + 44) * scale
            case .list:
                let lines = block.list.reduce(0) { $0 + lineCount(String($1.text.characters), width: textWidth - DS.Space.xxl, scale: scale) }
                return (CGFloat(lines) * lineHeight + CGFloat(block.list.count) * DS.Space.s + 2 * DS.Space.s) * scale
            case .separator: return 31
            case .image: return (ChatImageBox.height + 2 * DS.Space.s) * scale
            default: return textHeight(String(block.text.characters), width: textWidth, scale: scale)
            }
        case .omitted: return 96 * scale
        case .showAll: return 60 * scale
        case .toolGroup, .turnSummary, .turnFooter: return DS.Size.touchTarget * scale
        case .item(let item):
            switch item.body {
            case .plan(let plan): return CGFloat(min(plan.entries.count, 20) * 30 + 64) * scale
            case .user(let user):
                return bubbleHeight(row.preview ?? user.text, width: textWidth, scale: scale)
            case .longText(let longText) where longText.role == .known(.user):
                return bubbleHeight(row.preview ?? longText.content.preview, width: textWidth, scale: scale)
            case .assistant(let assistant): return textHeight(assistant.text, width: textWidth, scale: scale)
            case .longText(let longText) where longText.role != .known(.thinking):
                return textHeight(row.preview ?? longText.content.preview, width: textWidth, scale: scale)
            default: return 64 * scale
            }
        }
    }

    private static func textHeight(_ text: String, width: CGFloat, scale: CGFloat) -> CGFloat {
        max(64 * scale, (CGFloat(lineCount(text, width: width, scale: scale)) * lineHeight + 2 * DS.Space.s) * scale)
    }

    private static func bubbleHeight(_ text: String, width: CGFloat, scale: CGFloat) -> CGFloat {
        let lines = lineCount(text, width: width - DS.Space.xxxl - 2 * DS.Space.l, scale: scale)
        return max(64 * scale, (CGFloat(lines) * lineHeight + 2 * DS.Space.m + 2 * DS.Space.s + DS.Size.touchTarget) * scale)
    }

    static func lineCount(_ text: String, width: CGFloat, scale: CGFloat) -> Int {
        let charactersPerLine = max(1, Int(width / (averageCharacterWidth * max(scale, 0.5))))
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, (line.utf8.count + charactersPerLine - 1) / charactersPerLine)
        }
    }
}
