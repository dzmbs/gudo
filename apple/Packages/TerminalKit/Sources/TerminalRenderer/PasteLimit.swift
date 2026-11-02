import Foundation
import TerminalCore

/// What a paste past `Terminal.maxPasteBytes` tells the user.
enum PasteLimit {
    static let title = "Text Too Large to Paste"

    static func message(bytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: Int64(Terminal.maxPasteBytes), countStyle: .file)
        return "This text is \(size). A terminal takes pastes up to \(limit); save larger text to a file and copy the file to the host instead."
    }
}
