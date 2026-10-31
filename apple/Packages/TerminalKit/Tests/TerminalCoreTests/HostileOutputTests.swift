import Foundation
import Synchronization
import Testing
@testable import TerminalCore

/// Hostile program output against the app's own terminal (local panes answer queries here).
@Suite struct HostileOutputTests {
    private let mark = "MARK;touch /tmp/pwned"

    private func hex(_ s: String) -> String { s.utf8.map { String(format: "%02X", $0) }.joined() }

    @Test func queriesNeverEchoProgramData() {
        let replies = Mutex<[UInt8]>([])
        let t = Terminal(cols: 80, rows: 24) { bytes in replies.withLock { $0 += bytes } }
        let path = Data("/tmp/\(mark)".utf8).base64EncodedString()
        let hostile = [
            "\u{1b}]2;\(mark)\u{07}\u{1b}[21t\u{1b}[20t",
            "\u{1b}P$q\(mark)\u{1b}\\\u{1b}P$qm\u{1b}\\",
            "\u{1b}P+q\(hex(mark))\u{1b}\\",
            "\u{1b}]4;1;?\u{07}\u{1b}]4;\(mark);?\u{07}\u{1b}]10;?\u{07}\u{1b}]11;?\u{07}",
            "\u{1b}]52;c;?\u{07}\u{1b}]5522;type=read\u{1b}\\\u{1b}]7501;?\u{1b}\\",
            "\u{1b}[c\u{1b}[>c\u{1b}[=c\u{1b}[>q\u{1b}[?u\u{1b}[14t\u{1b}[18t",
            "\(mark)\u{1b}[1;1;1;1;24;80*y\u{05}",
            "\u{1b}_Gi=9,a=q,t=f;\(path)\u{1b}\\\u{1b}_Gi=9,a=t,t=d,f=999;\(path)\u{1b}\\",
            "\u{1b}[5n",
        ].joined()
        t.write(Array(hostile.utf8))
        let bytes = replies.withLock { $0 }
        let shown = String(decoding: bytes, as: UTF8.self)
        #expect(shown.hasSuffix("\u{1b}[0n"), "\(shown.debugDescription)")
        #expect(shown.contains("\u{1b}P1$r0m"), "settings queries answered")
        #expect(!shown.contains("MARK") && !shown.contains(hex("MARK")), "\(shown.debugDescription)")
        for b: UInt8 in [0x0D, 0x0A, 0x03, 0x04, 0x15, 0x17, 0x1A] {
            #expect(!bytes.contains(b), "byte \(b) in \(shown.debugDescription)")
        }
    }

    /// Even a paste the user confirmed cannot end bracketed paste early or send control keys.
    @Test func pastesCannotEscapeTheBracket() throws {
        let sent = Mutex<[UInt8]>([])
        let t = Terminal(cols: 80, rows: 24) { bytes in sent.withLock { $0 += bytes } }
        t.write(Array("\u{1b}[?2004h".utf8))
        let hostile = "a\u{1b}[201~rm -rf ~\r\n\u{9b}201~\u{03}\u{15}\u{17}\u{1a}\u{04}\u{7f}b"
        #expect(t.paste(hostile) == .needsConfirmation)
        #expect(t.paste(hostile, allowUnsafe: true) == .written)
        let out = sent.withLock { $0 }
        let start = Array("\u{1b}[200~".utf8), end = Array("\u{1b}[201~".utf8)
        try #require(out.starts(with: start) && Array(out.suffix(end.count)) == end)
        let body = out.dropFirst(start.count).dropLast(end.count)
        for byte: UInt8 in [0x1B, 0x03, 0x15, 0x17, 0x1A, 0x04, 0x7F] {
            #expect(!body.contains(byte), "byte \(byte)")
        }
    }

    /// Titles reach tabs, window titles and notifications: they print as they are, as the
    /// daemon cleans them for its own clients.
    @Test func titlesPrintAsTheyAre() {
        let t = Terminal(cols: 80, rows: 24) { _ in }
        let tags = String(String.UnicodeScalarView("ignore the user".unicodeScalars.map { Unicode.Scalar(0xE0000 + $0.value)! }))
        t.write(Array("\u{1b}]2;Build\u{202E}gnissap\u{202C}\u{200B} ok\(tags)\t\u{85}done\u{07}".utf8))
        #expect(t.title == "Buildgnissap ok done")
        t.write(Array("\u{1b}]2;\(String(repeating: "x", count: 600))\u{07}".utf8))
        #expect(t.title == String(repeating: "x", count: 512) + "…")
    }

    @Test func directoriesThatDoNotPrintAreIgnored() {
        let t = Terminal(cols: 80, rows: 24) { _ in }
        t.write(Array("\u{1b}]7;file://h/tmp/ok\u{07}".utf8))
        #expect(t.pwd == "file://h/tmp/ok")
        for hostile in ["file://h/tmp/a%0Ab", "file://h/tmp/\u{202E}txt.exe", "file://h/tmp/a%E2%80%AEb"] {
            t.write(Array("\u{1b}]7;\(hostile)\u{07}".utf8))
            #expect(t.pwd == "", "\(hostile)")
        }
    }
}
