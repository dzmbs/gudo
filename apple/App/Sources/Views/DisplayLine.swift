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
}
