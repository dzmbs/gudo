import GhosttyVt

public enum PasteResult: Sendable, Equatable {
    /// The text went to the PTY (through `writeInput`, or `writePty` as a fallback).
    case written
    /// Nothing to paste (empty text).
    case empty
    /// Unbracketed text with a newline, or text containing the bracketed-paste terminator: it
    /// could run commands. Nothing was written; confirm with the user and paste again with
    /// `allowUnsafe`.
    case needsConfirmation
    /// Longer than `Terminal.maxPasteBytes`: nothing was written; tell the user.
    case tooLarge
    case failed
}

extension Terminal {
    /// The longest paste sent to a terminal. Past this it is a file transfer: framing it blocks
    /// the caller for seconds and doubles the memory it holds, and the program reads it a line
    /// at a time anyway.
    public static let maxPasteBytes = 16 << 20

    /// Pastes `text` the way Ghostty does (`ghostty_terminal_paste`): bracketed when DECSET 2004 is
    /// on (otherwise newlines become CR), unsafe control bytes replaced, and a kitty paste event
    /// instead when the program asked for one. The bytes go through `writeInput` when supplied.
    ///
    /// - Parameter source: `.clipboard` for a user paste; `.text` for IME commits, dictation,
    ///   composer submissions and drops.
    public func paste(_ text: String, source: PasteSource = .clipboard, allowUnsafe: Bool = false) -> PasteResult {
        guard !text.isEmpty else { return .empty }
        guard text.utf8.count <= Self.maxPasteBytes else { return .tooLarge }
        let box = PasteBox(bytes: Array(text.utf8))
        let reader: GhosttyMimeReaderFn = { userdata, _, writer in
            guard let userdata else { return false }
            let box = Unmanaged<PasteBox>.fromOpaque(userdata).takeUnretainedValue()
            return box.bytes.withUnsafeBufferPointer { writer.write(writer.userdata, $0.baseAddress!, $0.count) }
        }
        let mime = Array("text/plain".utf8)
        return mime.withUnsafeBufferPointer { mimeBytes in
            var mimes = [GhosttyString(ptr: mimeBytes.baseAddress, len: mimeBytes.count)]
            return mimes.withUnsafeMutableBufferPointer { mimes in
                var paste = GhosttyPaste()
                paste.size = MemoryLayout<GhosttyPaste>.size
                paste.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD
                paste.source = source == .clipboard ? GHOSTTY_PASTE_SOURCE_CLIPBOARD : GHOSTTY_PASTE_SOURCE_TEXT
                paste.mimes = UnsafePointer(mimes.baseAddress)
                paste.mimes_len = 1
                paste.reader = GhosttyMimeReader(read: reader, userdata: Unmanaged.passUnretained(box).toOpaque())
                paste.allow_unsafe = allowUnsafe
                var written = false
                let result = withExtendedLifetime(box) {
                    withHandle { terminal in
                        // The terminal lock prevents output/query callbacks from borrowing paste provenance.
                        effects.isPasting.store(true, ordering: .relaxed)
                        defer { effects.isPasting.store(false, ordering: .relaxed) }
                        return ghostty_terminal_paste(terminal, &paste, &written)
                    }
                }
                switch result {
                case GHOSTTY_SUCCESS: return written ? .written : .empty
                case GHOSTTY_REJECTED: return .needsConfirmation
                default: return .failed
                }
            }
        }
    }

    /// The lines a paste confirmation names: line breaks, plus a last line without one. One
    /// pass over the bytes, so asking stays instant for any size.
    public static func pasteLineCount(_ text: String) -> Int {
        var text = text
        return text.withUTF8 { bytes in
            var lines = 0
            var last: UInt8 = 0
            for byte in bytes {
                // CR LF is one break.
                if byte == 0x0D || (byte == 0x0A && last != 0x0D) { lines += 1 }
                last = byte
            }
            return bytes.isEmpty || last == 0x0A || last == 0x0D ? lines : lines + 1
        }
    }

    /// Ghostty's conservative check (no newline, no paste terminator), independent of modes.
    public static func isSafePaste(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress.map { $0.withMemoryRebound(to: CChar.self, capacity: buffer.count) { ghostty_paste_is_safe($0, buffer.count) } } ?? true
        }
    }
}

public enum PasteSource: Sendable { case clipboard, text }

private final class PasteBox {
    let bytes: [UInt8]
    init(bytes: [UInt8]) { self.bytes = bytes }
}
