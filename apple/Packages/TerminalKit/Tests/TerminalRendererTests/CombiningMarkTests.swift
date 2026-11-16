import CoreText
import Testing
@testable import TerminalRenderer

/// A letter with combining marks draws whole, letter and marks in one face, as in Ghostty: the
/// marks are never dropped and the letter never moves to another font for them.
struct CombiningMarkTests {
    private let fonts = FontGrid(pixelSize: 26)

    private func glyph(_ scalars: [UInt32]) -> RenderedGlyph? {
        fonts.glyph(for: scalars, style: .regular, span: 1)
    }

    @Test(arguments: [
        [UInt32(0x65), 0x30A],         // e with ring above
        [UInt32(0x61), 0x20D7],        // a with a right arrow above
        [UInt32(0x6F), 0x308],         // o with diaeresis
        [UInt32(0x5A), 0x301, 0x316, 0x334], // stacked marks above, below and through
    ])
    func marksDrawWithTheirLetter(_ cluster: [UInt32]) throws {
        let letter = try #require(glyph([cluster[0]]))
        let whole = try #require(glyph(cluster), "the cluster draws")
        let letterTop = letter.offsetY - letter.region.height
        let wholeTop = whole.offsetY - whole.region.height
        let reaches = whole.region.height > letter.region.height || wholeTop < letterTop || whole.offsetY > letter.offsetY
        #expect(reaches, "the marks add to the letter: \(whole) vs \(letter)")
    }

    @Test func theLetterStaysInThePrimaryFaceWhenItHasTheMarks() throws {
        let primary = CTFontCreateWithName("Menlo-Regular" as CFString, 26, nil)
        let scalars: [Unicode.Scalar] = ["e", "\u{30A}"]
        let face = try #require(fonts.clusterFace(scalars, primary: primary))
        #expect(CTFontCopyPostScriptName(face) as String == "Menlo-Regular")
    }

    @Test func aFaceThatHasEveryCodepointIsChosenForTheWholeCluster() throws {
        let primary = CTFontCreateWithName("Menlo-Regular" as CFString, 26, nil)
        let scalars: [Unicode.Scalar] = ["a", "\u{20D7}"]
        let face = try #require(fonts.clusterFace(scalars, primary: primary), "some face has both")
        for scalar in scalars {
            var glyph = CGGlyph()
            let utf16 = Array(String(scalar).utf16)
            #expect(CTFontGetGlyphsForCharacters(face, utf16, &glyph, utf16.count) && glyph != 0, "\(CTFontCopyPostScriptName(face)) has U+\(String(scalar.value, radix: 16))")
        }
    }
}
