import Foundation

extension TerminalView {
    /// File URLs become shell-escaped paths; ordinary URLs keep their textual representation.
    public func pasteURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pasteText(urls.map { $0.isFileURL ? Self.shellQuoted($0.path) : $0.absoluteString }.joined(separator: " "))
    }

    static func shellQuoted(_ path: String) -> String {
        let plain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+,:@%".contains($0) }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
