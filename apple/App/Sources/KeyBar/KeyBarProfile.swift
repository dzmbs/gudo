import Foundation
import TerminalCore

/// What the key bar knows about the focused pane: the foreground program when the backend reports
/// it (daemon: `tcgetpgrp`), else only the terminal title (OSC 0/2).
struct KeyBarContext: Equatable {
    var program: String?
    var title: String
}

/// One key-bar key: tap sends `output`; a long-press offers `alternate` in a small menu.
/// Built from a key or a character plus modifiers, never from raw escape strings, so it goes
/// through the terminal's encoder (application-cursor mode, kitty keyboard protocol).
struct KeySpec: Identifiable {
    enum Output {
        case key(PhysicalKey, KeyModifiers)
        /// A character, typed like on a US layout (so Ctrl+c encodes as 0x03).
        case text(String, KeyModifiers)
        /// Several events in a row ("esc esc", a prefix then a key).
        case sequence([Output])
        /// The clipboard, pasted the way the terminal pastes (bracketed when the program asks).
        case paste
    }

    var id: String
    var title: String?
    var symbol: String?
    var accessibilityLabel: String
    /// Repeats while held (⌫, arrows). Repeating keys have no long-press menu.
    var repeatable = false
    var output: Output
    var alternate: Output?
    var alternateTitle: String?

    func events(latched: KeyModifiers, alternate useAlternate: Bool = false) -> [KeyEvent] {
        Self.events(useAlternate ? (alternate ?? output) : output, latched: latched)
    }

    /// Only for repeating keys, which are always a single plain event.
    func event(latched: KeyModifiers) -> KeyEvent {
        events(latched: latched)[0]
    }

    private static func events(_ output: Output, latched: KeyModifiers) -> [KeyEvent] {
        switch output {
        case .key(let key, let modifiers): [.press(key, mods: modifiers.union(latched))]
        case .text(let text, let modifiers): [.typing(text, mods: modifiers.union(latched))]
        case .paste: []
        // Latched modifiers apply to the first event only (a prefix key, then a plain key).
        case .sequence(let parts):
            parts.enumerated().flatMap { index, part in events(part, latched: index == 0 ? latched : []) }
        }
    }

    func flick(_ alternate: Output, title: String) -> KeySpec {
        var key = self
        key.alternate = alternate
        key.alternateTitle = title
        key.repeatable = false
        return key
    }
}

extension KeySpec {
    static func key(_ id: String, _ key: PhysicalKey, mods: KeyModifiers = [], title: String? = nil, symbol: String? = nil, label: String, repeatable: Bool = false) -> KeySpec {
        KeySpec(id: id, title: title, symbol: symbol, accessibilityLabel: label, repeatable: repeatable, output: .key(key, mods))
    }

    static func text(_ id: String, _ text: String, mods: KeyModifiers = [], title: String? = nil, label: String) -> KeySpec {
        KeySpec(id: id, title: title ?? text, accessibilityLabel: label, output: .text(text, mods))
    }

    /// Ctrl+letter as a direct key ("^C"); never repeats (destructive keys don't).
    static func ctrl(_ letter: String, label: String) -> KeySpec {
        .text("ctrl-\(letter)", letter, mods: .control, title: "^\(letter.uppercased())", label: label)
    }

    /// A key that types `tap`, with `flick` in its long-press menu.
    static func pair(_ id: String, _ tap: String, _ flick: String, label: String) -> KeySpec {
        text(id, tap, label: label).flick(.text(flick, []), title: flick)
    }

    static func ctrlPair(_ tap: String, _ flick: String, label: String) -> KeySpec {
        ctrl(tap, label: label).flick(.text(flick, .control), title: "^\(flick.uppercased())")
    }

    static let esc = key("esc", .escape, title: "esc", label: "Escape")
    static let tab = key("tab", .tab, symbol: "arrow.right.to.line", label: "Tab")
    static let shiftTab = key("shift-tab", .tab, mods: .shift, symbol: "arrow.left.to.line", label: "Shift Tab")
    static let mode = key("mode", .tab, mods: .shift, title: "⇧tab", label: "Shift Tab, switch mode")
    static let enter = key("enter", .enter, symbol: "return", label: "Return")
    static let up = key("up", .arrowUp, symbol: "arrow.up", label: "Up arrow", repeatable: true)
    static let down = key("down", .arrowDown, symbol: "arrow.down", label: "Down arrow", repeatable: true)
    static let left = key("left", .arrowLeft, symbol: "arrow.left", label: "Left arrow", repeatable: true)
    static let right = key("right", .arrowRight, symbol: "arrow.right", label: "Right arrow", repeatable: true)
    // USB HID usages for keys PhysicalKey has no named constant for.
    static let home = key("home", PhysicalKey(hidUsage: 0x4A)!, title: "Home", label: "Home")
    static let end = key("end", PhysicalKey(hidUsage: 0x4D)!, title: "End", label: "End")
    static let pageUp = key("pgup", PhysicalKey(hidUsage: 0x4B)!, title: "PgUp", label: "Page up", repeatable: true)
    static let pageDown = key("pgdn", PhysicalKey(hidUsage: 0x4E)!, title: "PgDn", label: "Page down", repeatable: true)
    static let backspace = key("backspace", .backspace, symbol: "delete.left", label: "Delete", repeatable: true)
    static let paste = KeySpec(id: "paste", symbol: "doc.on.clipboard", accessibilityLabel: "Paste", output: .paste)
    static let rewind = KeySpec(id: "rewind", title: "esc²", accessibilityLabel: "Escape twice, rewind",
                                output: .sequence([.key(.escape, []), .key(.escape, [])]))

    /// F1–F12 (HID usages 0x3A–0x45).
    static func function(_ number: Int) -> Output {
        .key(PhysicalKey(hidUsage: UInt32(0x39 + number))!, [])
    }

    static func fkey(_ number: Int, flick: String, label: String) -> KeySpec {
        KeySpec(id: "f\(number)", title: "F\(number)", accessibilityLabel: label, output: function(number))
            .flick(.text(flick, []), title: flick)
    }
}

/// A context-aware key set. Profiles only change the scrolling keys after the arrows;
/// `esc ctrl alt ⇥` and the arrows are the same everywhere. Matched by foreground program,
/// else by title.
struct KeyBarProfile: Identifiable, Equatable {
    var id: String
    var name: String
    /// Foreground process names (basename, lowercased) that select this profile.
    var programs: Set<String>
    /// Matched against the lowercased title when the program is unknown.
    var titlePattern: String?
    /// Most used first: a narrow bar shows the first ones and scrolls to the rest.
    var keys: [KeySpec]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    static let shell = KeyBarProfile(
        id: "shell", name: "Shell", programs: ["bash", "zsh", "fish", "sh", "dash", "nu", "pwsh"], titlePattern: nil,
        keys: [
            .pair("tilde", "~", "$", label: "Tilde"), .pair("pipe", "|", "&", label: "Vertical bar"),
            .pair("slash", "/", "\\", label: "Slash"), .pair("dash", "-", "_", label: "Hyphen"),
            .backspace, .paste, .text("backslash", "\\", label: "Backslash"),
            .pair("backtick", "`", "'", label: "Backtick"), .pair("star", "*", "?", label: "Star"),
            .pair("dollar", "$", "#", label: "Dollar"), .pair("gt", ">", "<", label: "Greater than"),
            .ctrlPair("r", "s", label: "Control R, history search"),
        ])

    static let vim = KeyBarProfile(
        id: "vim", name: "Vim", programs: ["vim", "nvim", "vi", "view", "vimdiff", "hx", "micro"], titlePattern: #"\bn?vim?\b"#,
        keys: [
            .pair("colon", ":", ";", label: "Colon"), .pair("slash", "/", "?", label: "Search"),
            .pair("dot", ".", "%", label: "Repeat"),
            .text("u", "u", label: "Undo").flick(.text("r", .control), title: "^R"),
            .backspace, .paste, .pair("star", "*", "#", label: "Search word"), .text("percent", "%", label: "Match bracket"),
            .ctrl("r", label: "Control R, redo"), .ctrlPair("v", "a", label: "Control V, block select"),
            .ctrlPair("w", "o", label: "Control W, window"), .ctrlPair("d", "u", label: "Control D, half page down"),
        ])

    static let pager = KeyBarProfile(
        id: "pager", name: "Pager", programs: ["less", "more", "man", "most", "bat"],
        titlePattern: #"\b(less|more|man)\b"#,
        keys: [
            .pair("q", "q", "Q", label: "Quit"), .pair("slash", "/", "?", label: "Search"),
            .text("n", "n", label: "Next match"), .text("N", "N", label: "Previous match"),
            .backspace, .pair("g", "g", "G", label: "Top"), .text("G", "G", label: "Bottom"),
            .text("space", " ", title: "␣", label: "Space, next page").flick(.text("b", []), title: "b"),
            .pageDown, .pageUp,
        ])

    static let monitor = KeyBarProfile(
        id: "monitor", name: "Monitor", programs: ["htop", "top", "btop", "glances", "atop"],
        titlePattern: #"\b(htop|top|btop|glances)\b"#,
        keys: [
            .fkey(10, flick: "q", label: "F10, quit"), .fkey(6, flick: ">", label: "F6, sort"),
            .fkey(3, flick: "/", label: "F3, search"), .fkey(9, flick: "k", label: "F9, kill"),
            .text("space", " ", title: "␣", label: "Space, tag").flick(.text("u", []), title: "u"),
            .fkey(4, flick: "\\", label: "F4, filter"), .fkey(5, flick: "t", label: "F5, tree"),
            .fkey(2, flick: "S", label: "F2, setup"), .pair("plus", "+", "-", label: "Expand"),
        ])

    static let tmux = KeyBarProfile(
        id: "tmux", name: "tmux", programs: ["tmux"], titlePattern: #"\btmux\b"#,
        keys: [
            .ctrlPair("b", "a", label: "Control B, tmux prefix"),
            prefixed("c", ",", label: "New window"), prefixed("n", "p", label: "Next window"),
            prefixed("%", "\"", label: "Split"), .backspace, prefixed("o", ";", label: "Next pane"),
            prefixed("z", "x", label: "Zoom pane"), prefixed("[", "]", label: "Copy mode"),
            prefixed("d", "$", label: "Detach"), prefixed("w", "s", label: "Choose window"),
        ])

    static let claude = KeyBarProfile(
        id: "claude", name: "Claude Code", programs: ["claude"],
        // Claude Code titles its terminal "✳ <task>" (a spinner glyph while working).
        titlePattern: #"\bclaude\b|^[✳✻✽✶✢·]\s"#,
        keys: [
            .mode, .pair("slash", "/", "#", label: "Slash command"), .pair("at", "@", "!", label: "Mention file"),
            .text("bang", "!", label: "Bash mode"), .backspace, .ctrlPair("c", "r", label: "Control C"),
            .paste, .text("hash", "#", label: "Memory"), .ctrlPair("o", "b", label: "Control O, expand"),
            .rewind.flick(.key(.arrowUp, []), title: "↑"),
        ])

    static let codex = KeyBarProfile(
        id: "codex", name: "Codex", programs: ["codex"], titlePattern: #"\bcodex\b"#,
        keys: [
            .pair("slash", "/", "@", label: "Slash command"), .text("at", "@", label: "Mention file"),
            .backspace, .ctrlPair("c", "j", label: "Control C"), .enter,
            .paste, .ctrl("j", label: "Control J, newline"), .ctrlPair("t", "o", label: "Control T, transcript"),
            .rewind.flick(.key(.arrowUp, []), title: "↑"),
        ])

    static let repl = KeyBarProfile(
        id: "repl", name: "REPL",
        programs: ["python", "python3", "ipython", "node", "irb", "psql", "sqlite3", "ghci", "iex", "deno", "bun"],
        titlePattern: #"\b(python3?|ipython|irb|psql|sqlite3)\b"#,
        keys: [
            .pair("lparen", "(", ")", label: "Parenthesis"), .pair("quote", "\"", "'", label: "Quote"),
            .pair("colon", ":", ";", label: "Colon"), .pair("lbracket", "[", "]", label: "Bracket"),
            .backspace, .pair("lbrace", "{", "}", label: "Brace"), .pair("eq", "=", "+", label: "Equals"),
            .paste, .ctrlPair("d", "l", label: "Control D"), .ctrlPair("r", "c", label: "Control R"),
        ])

    /// tmux's prefix (^B) followed by a key; the flick sends the prefix and the alternate.
    private static func prefixed(_ tap: String, _ flick: String, label: String) -> KeySpec {
        let prefix = KeySpec.Output.text("b", .control)
        return KeySpec(id: "tmux-\(tap)", title: tap, accessibilityLabel: label,
                       output: .sequence([prefix, .text(tap, [])]))
            .flick(.sequence([prefix, .text(flick, [])]), title: flick)
    }

    /// Built-in profiles, most specific first; `shell` is the fallback.
    static let builtIn: [KeyBarProfile] = [.claude, .codex, .vim, .tmux, .monitor, .pager, .repl, .shell]

    static func match(_ context: KeyBarContext, among profiles: [KeyBarProfile] = builtIn) -> KeyBarProfile {
        if let program = context.program.map({ ($0 as NSString).lastPathComponent.lowercased() }),
           let profile = profiles.first(where: { $0.programs.contains(program) })
        {
            return profile
        }
        let title = context.title.lowercased()
        if !title.isEmpty {
            for profile in profiles {
                guard let pattern = profile.titlePattern else { continue }
                if title.range(of: pattern, options: .regularExpression) != nil { return profile }
            }
        }
        return profiles.first { $0.id == "shell" } ?? .shell
    }
}
