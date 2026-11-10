import CoreText
import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated struct NativeTextDocument: Sendable {
    struct Input: Hashable, Sendable {
        var text: String
        var numbered: Bool
        var truncated: Bool
        var width: CGFloat
        var lineHeight: CGFloat
        var fontSize: CGFloat
    }

    var lines: [String]
    var layout: NativeListLayout
    var gutterWidth: CGFloat

    init(input: Input) {
        lines = input.numbered
            ? input.text.components(separatedBy: "\n").map(DisplayLine.capped)
            : input.text.components(separatedBy: "\n\n")
        let characterWidth = input.lineHeight * 0.55
        gutterWidth = input.numbered ? CGFloat(max(3, String(lines.count).count)) * characterWidth + 16 : 0
        #if os(macOS)
        let fontName = NSFont.monospacedSystemFont(ofSize: input.fontSize, weight: .regular).fontName
        #else
        let fontName = UIFont.monospacedSystemFont(ofSize: input.fontSize, weight: .regular).fontName
        #endif
        let font = CTFontCreateWithName(fontName as CFString, input.fontSize, nil)
        let fontLineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        var longestLine = 0
        var rows: [NativeListRow] = []
        rows.reserveCapacity(lines.count + 1)
        for (index, line) in lines.enumerated() {
            longestLine = max(longestLine, line.utf16.count)
            let height: CGFloat
            if input.numbered {
                height = input.lineHeight
            } else {
                let string = NSAttributedString(string: line.isEmpty ? " " : line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                let framesetter = CTFramesetterCreateWithAttributedString(string)
                let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                    CGSize(width: max(40, input.width - 32), height: .greatestFiniteMagnitude), nil)
                let lineCount = ceil(size.height / max(1, fontLineHeight))
                height = max(input.lineHeight, lineCount * ceil(fontLineHeight)) + 12
            }
            rows.append(NativeListRow(id: "text:\(index)", height: height, scrollsHorizontally: input.numbered))
        }
        if input.truncated { rows.append(NativeListRow(id: "truncated", height: 72)) }
        let width = input.numbered ? max(input.width, CGFloat(longestLine) * characterWidth + gutterWidth + 16) : input.width
        layout = NativeListLayout(rows: rows, contentWidth: width)
    }
}

struct NativeTextPreview: View {
    let text: String
    var numbered = true
    var truncated = false
    @Environment(\.terminalTheme) private var theme
    @State private var width: CGFloat = 800
    @State private var document: NativeTextDocument?
    #if os(macOS)
    @ScaledMetric(relativeTo: .callout) private var lineHeight: CGFloat = 18
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 11
    #else
    @ScaledMetric(relativeTo: .callout) private var lineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    #endif

    var body: some View {
        let input = NativeTextDocument.Input(text: text, numbered: numbered, truncated: truncated,
            width: width, lineHeight: ceil(lineHeight), fontSize: captionSize)
        Group {
            if let document {
                NativeVirtualList(document: document.layout) { index in
                    if index < document.lines.count {
                        if numbered {
                            HStack(spacing: 0) {
                                Text("\(index + 1)")
                                    .font(DS.Font.literal.monospacedDigit())
                                    .foregroundStyle(DS.Palette.textQuaternary)
                                    .padding(.horizontal, DS.Space.s)
                                    .frame(width: document.gutterWidth, alignment: .trailing)
                                Text(verbatim: document.lines[index].isEmpty ? " " : document.lines[index])
                                    .font(DS.Font.literal)
                                    .foregroundStyle(theme.foreground)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .textSelection(.enabled)
                                Spacer(minLength: DS.Space.l)
                            }
                            .frame(height: ceil(lineHeight))
                        } else {
                            Text(verbatim: document.lines[index])
                                .font(.system(size: captionSize, design: .monospaced))
                                .foregroundStyle(theme.foreground)
                                .textSelection(.enabled)
                                .padding(.horizontal, DS.Space.l)
                                .padding(.vertical, DS.Space.xs)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    } else {
                        Text("Showing the first MiB. Download the file or open it in VS Code for the rest.")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .padding(DS.Space.l)
                    }
                }
            } else {
                Color.clear
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: input) {
            let value = await Task.detached(priority: .userInitiated) { NativeTextDocument(input: input) }.value
            guard !Task.isCancelled else { return }
            document = value
        }
        .background(theme.background)
    }
}
