import Testing
@testable import TerminalRenderer

struct EmojiPresentationTests {
    private let fonts = FontGrid(pixelSize: 26)

    private func atlas(_ scalars: [UInt32], span: Int = 1) -> CellText.Atlas? {
        fonts.glyph(for: scalars, style: .regular, span: span)?.atlas
    }

    @Test func spinnerDingbatsAreTextInTheForegroundColor() {
        for codepoint: UInt32 in [0xB7, 0x2722, 0x2733, 0x2736, 0x273B, 0x273D] {
            #expect(atlas([codepoint]) == .grayscale, "U+\(String(codepoint, radix: 16, uppercase: true))")
        }
    }

    @Test func symbolsWithoutEmojiPresentationAreText() {
        for codepoint: UInt32 in [0x2714, 0x2764, 0x2611, 0x2713, 0x2717, 0x21BA] {
            #expect(atlas([codepoint]) == .grayscale, "U+\(String(codepoint, radix: 16, uppercase: true))")
        }
    }

    @Test func variationSelectorSixteenAsksForTheColorEmoji() {
        #expect(atlas([0x2733, 0xFE0F]) == .color)
        #expect(atlas([0x2764, 0xFE0F], span: 2) == .color)
    }

    @Test func emojiPresentationCharactersStayColor() {
        #expect(atlas([0x1F558], span: 2) == .color)
        #expect(atlas([0x2705], span: 2) == .color)
        #expect(atlas([0x26A1], span: 2) == .color)
        #expect(atlas([0x2B50], span: 2) == .color)
    }

    @Test func variationSelectorFifteenAsksForText() {
        #expect(atlas([0x26A1, 0xFE0E]) == .grayscale)
    }

    @Test func powerlineAndPromptGlyphsStayInTheTextFace() {
        for codepoint: UInt32 in [0xE0B0, 0xE0B2, 0xE0B3, 0xF015, 0xE0A0, 0x276F] {
            #expect(atlas([codepoint]) == .grayscale, "U+\(String(codepoint, radix: 16, uppercase: true))")
        }
    }

    @Test func presentationFollowsSelectorsThenTheProperty() {
        func presentation(_ values: [UInt32]) -> EmojiPresentation {
            EmojiPresentation(values.compactMap(Unicode.Scalar.init))
        }
        #expect(presentation([0x2733]) == .text)
        #expect(presentation([0x2733, 0xFE0F]) == .emoji)
        #expect(presentation([0x1F558]) == .emoji)
        #expect(presentation([0x1F558, 0xFE0E]) == .text)
        #expect(presentation([0x41]) == .text)
    }
}
