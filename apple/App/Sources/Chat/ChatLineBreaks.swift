import Foundation

/// Agents wrap their prose at the terminal's width, so a single newline inside inline Markdown
/// is a soft break and reads as a space. Two trailing spaces or a backslash make a hard break.
nonisolated enum ChatLineBreaks {
    static func joiningSoftBreaks(_ source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        guard scalars.contains(where: isNewline) else { return source }
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count {
                if isNewline(scalars[index + 1]) {
                    output.append(contentsOf: "\\\n".unicodeScalars)
                    index = skipLineStart(scalars, from: index + 1)
                } else {
                    output.append(scalar)
                    output.append(scalars[index + 1])
                    index += 2
                }
            } else if scalar == "`" {
                index = appendCodeSpan(scalars, from: index, to: &output)
            } else if isNewline(scalar) {
                var trailingSpaces = 0
                while let last = output.last, last == " " || last == "\t" {
                    if last == " " { trailingSpaces += 1 }
                    output.removeLast()
                }
                index = skipLineStart(scalars, from: index)
                if index < scalars.count { output.append(trailingSpaces >= 2 ? "\n" : " ") }
            } else {
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    private static func appendCodeSpan(_ scalars: [Unicode.Scalar], from start: Int,
                                       to output: inout String.UnicodeScalarView) -> Int {
        let fence = backtickRun(scalars, at: start)
        var search = start + fence
        while search < scalars.count {
            if scalars[search] == "`" {
                let run = backtickRun(scalars, at: search)
                if run == fence {
                    for scalar in scalars[start..<search + run] {
                        if scalar == "\r" { continue }
                        output.append(scalar == "\n" ? " " : scalar)
                    }
                    return search + run
                }
                search += run
            } else {
                search += 1
            }
        }
        output.append(contentsOf: scalars[start..<start + fence])
        return start + fence
    }

    private static func backtickRun(_ scalars: [Unicode.Scalar], at start: Int) -> Int {
        var end = start
        while end < scalars.count, scalars[end] == "`" { end += 1 }
        return end - start
    }

    private static func skipLineStart(_ scalars: [Unicode.Scalar], from newline: Int) -> Int {
        var index = newline + 1
        if scalars[newline] == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        return index
    }

    private static func isNewline(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" }
}
