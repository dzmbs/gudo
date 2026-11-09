import Testing
@testable import TerminalCore

struct LineEditingKeyTests {
    struct Chord: Sendable, CustomTestStringConvertible {
        let key: PhysicalKey
        let mods: KeyModifiers
        let name: String
        var testDescription: String { name }
    }

    @Test func chordsSendShellLineEditing() {
        let expected: [(Chord, [UInt8])] = [
            (Chord(key: .arrowLeft, mods: .alt, name: "⌥←"), [0x1B, 0x62]),
            (Chord(key: .arrowRight, mods: .alt, name: "⌥→"), [0x1B, 0x66]),
            (Chord(key: .arrowLeft, mods: .super, name: "⌘←"), [0x01]),
            (Chord(key: .arrowRight, mods: .super, name: "⌘→"), [0x05]),
            (Chord(key: .backspace, mods: .super, name: "⌘⌫"), [0x15]),
            (Chord(key: .arrowLeft, mods: [.alt, .capsLock], name: "⌥← with caps lock"), [0x1B, 0x62]),
        ]
        for (chord, bytes) in expected {
            #expect(KeyEvent.press(chord.key, mods: chord.mods).lineEditingBytes == bytes, "\(chord.name)")
            let held = KeyEvent(key: chord.key, action: .repeat, mods: chord.mods, text: "", unshiftedCodepoint: 0)
            #expect(held.lineEditingBytes == bytes, "\(chord.name) held")
        }
    }

    @Test func releasesOfTheseChordsSendNothing() {
        let release = KeyEvent(key: .arrowLeft, action: .release, mods: .alt, text: "", unshiftedCodepoint: 0)
        #expect(release.lineEditingBytes == [])
    }

    @Test(arguments: [
        Chord(key: .arrowLeft, mods: [], name: "←"),
        Chord(key: .arrowLeft, mods: [.alt, .shift], name: "⇧⌥←"),
        Chord(key: .arrowLeft, mods: [.super, .alt], name: "⌥⌘←"),
        Chord(key: .arrowUp, mods: .alt, name: "⌥↑"),
        Chord(key: .backspace, mods: .alt, name: "⌥⌫"),
    ])
    func otherKeysEncodeNormally(chord: Chord) {
        #expect(KeyEvent.press(chord.key, mods: chord.mods).lineEditingBytes == nil)
    }
}
