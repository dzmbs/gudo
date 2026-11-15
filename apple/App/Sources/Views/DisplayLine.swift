import Foundation

/// A line as one row draws it: past `maximumCharacters` it ends in "…", so a minified file's
/// single line lays out like any other row instead of hanging the main thread.
nonisolated enum DisplayLine {
    static let maximumCharacters = 4_096

    static func capped(_ line: String) -> String {
        guard line.utf8.count > maximumCharacters else { return line }
        let kept = line.prefix(maximumCharacters)
        return kept.endIndex == line.endIndex ? line : kept + "…"
    }

    /// Every line of `text` capped; `text` itself when no line is too long.
    static func cappedLines(_ text: String) -> String {
        var lineLength = 0
        var isTooLong = false
        for byte in text.utf8 {
            lineLength = byte == UInt8(ascii: "\n") ? 0 : lineLength + 1
            if lineLength > maximumCharacters {
                isTooLong = true
                break
            }
        }
        guard isTooLong else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { capped(String($0)) }.joined(separator: "\n")
    }
}
