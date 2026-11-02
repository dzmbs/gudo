import Foundation
import GudoCore

/// How a shell command (OSC 133 marks) stands.
public enum CommandStatus: Equatable, Sendable {
    case running
    case succeeded
    /// A non-zero exit status.
    case failed(Int32)
    /// Finished without a status (the shell did not report one).
    case finished

    public init(_ mark: CommandMark) {
        switch mark.finished {
        case nil: self = .running
        case let end?:
            switch end.exit {
            case 0?: self = .succeeded
            case let code?: self = .failed(code)
            case nil: self = .finished
            }
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// One command's rows, named the way the daemon names rows (`RowAnchor`): rows above the
/// bottom of the screen at output offset `atSeq`, so the app can pin them in its own terminal
/// (`RowTracker`). From the prompt to the last row of output.
public struct CommandBlock: Equatable, Sendable {
    public var mark: CommandMark
    public var atSeq: UInt64
    /// The first row (the prompt, or the output when the prompt left scrollback).
    public var first: UInt64
    /// The last row; nil while the command runs (its output ends at the cursor).
    public var last: UInt64?
    /// `last` is the row of the end mark and the shell may have drawn its next prompt on it
    /// (it does when the output ended with a newline). Only the app's terminal can tell; when
    /// it is a prompt row, the block ends a row earlier.
    public var lastMayBePrompt: Bool

    public var status: CommandStatus { CommandStatus(mark) }
    public var id: UInt64 { mark.commandId }
}

/// Command blocks from a pane's command list, the words around them, and prompt jumps. Pure,
/// for tests; the app pins and draws them (`PaneCommandMarks`).
public enum CommandBlocks {
    /// The blocks still on the screen, oldest first. A command whose rows all left the
    /// scrollback has none.
    public static func blocks(_ list: CommandList) -> [CommandBlock] {
        guard list.totalRows > 0 else { return [] }
        let bottom = list.totalRows - 1
        let starts = list.commands.map { $0.promptRow ?? $0.outputRow }
        var blocks: [CommandBlock] = []
        for (index, info) in list.commands.enumerated() {
            guard let first = starts[index], first <= bottom else { continue }
            let next = starts[(index + 1)...].lazy.compactMap { $0 }.first
            var last: UInt64?
            var ambiguous = false
            if info.mark.finished != nil {
                if let end = info.endRow {
                    if let next, next > first {
                        // The next prompt starts on the end row (output ended with a newline)
                        // or the row after it (Ghostty's fresh-line after partial output).
                        last = min(end, next - 1)
                    } else {
                        last = end
                        ambiguous = end > first
                    }
                } else {
                    last = next.map { $0 > first ? $0 - 1 : first } ?? first
                }
                last = max(last ?? first, first)
            }
            blocks.append(CommandBlock(
                mark: info.mark, atSeq: list.atSeq, first: bottom - first,
                last: last.map { bottom - min($0, bottom) }, lastMayBePrompt: ambiguous))
        }
        return blocks
    }

    /// The pane's running command, if its newest command has not finished.
    public static func running(_ list: CommandList) -> CommandMark? {
        guard let newest = list.commands.last?.mark, newest.finished == nil else { return nil }
        return newest
    }

    /// The screen row to show at the top of the viewport for ⌘↑ (`direction` < 0) or ⌘↓ (> 0):
    /// the nearest prompt above or below the viewport's top row, as Ghostty's
    /// `jump_to_prompt` does. Nil when there is none that way (⌘↓ then goes to the bottom).
    public static func promptTarget(prompts: [Int], viewportTop: Int, direction: Int) -> Int? {
        let sorted = prompts.sorted()
        if direction < 0 { return sorted.last { $0 < viewportTop } }
        if direction > 0 { return sorted.first { $0 > viewportTop } }
        return nil
    }

    /// Run time in the sidebar's words: "8s", "1m 12s", "2h 03m".
    public static func elapsed(seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m"
    }

    /// The last line of output with something on it, trimmed (a notification body's "latest
    /// output").
    public static func lastLine(of output: String, limit: Int = 120) -> String? {
        let line = output.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    /// What Ask Agent types into an agent: the command, how it ended and its output, as plain
    /// text an agent's input box takes (no control characters, nothing that starts like a
    /// shell escape or an agent command, at most `limit` bytes: the end of long output kept).
    public static func agentPrompt(command: String?, status: CommandStatus, output: String, limit: Int = 12_000) -> String {
        let name = clean(command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let what = name.isEmpty ? "a command" : "`\(name)`"
        let outcome = switch status {
        case .failed(let code): " and it failed with exit status \(code)"
        case .succeeded: ""
        case .running: " (it is still running)"
        case .finished: ""
        }
        var body = clean(output).trimmingCharacters(in: .newlines)
        let head = "I ran \(what) in the terminal\(outcome). Its output:\n\n"
        let tail = "\n"
        let budget = max(0, limit - head.utf8.count - tail.utf8.count - 16)
        if body.utf8.count > budget {
            var cut = body.utf8.index(body.utf8.endIndex, offsetBy: -budget)
            // Never in the middle of a character, then from the next line.
            while cut < body.utf8.endIndex, String.Index(cut, within: body) == nil { cut = body.utf8.index(after: cut) }
            body = String(body[cut...])
            if let newline = body.firstIndex(of: "\n") { body = String(body[body.index(after: newline)...]) }
            body = "…\n" + body
        }
        if body.isEmpty { body = "(no output)" }
        return head + body + tail
    }

    /// Text without control characters other than newline and tab.
    static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar == "\n" || scalar == "\t" || scalar.properties.generalCategory != .control {
            out.append(scalar)
        }
        return String(out)
    }
}
