import Foundation
import TerminalCore

/// What the key bar knows about the focused pane: the foreground program when the backend reports
/// it (daemon: `tcgetpgrp`), else only the terminal title (OSC 0/2).
struct KeyBarContext: Equatable {
    var program: String?
    var title: String
}

/// Built from a key or a character plus modifiers, never from raw escape strings, so it goes
/// through the terminal's encoder (application-cursor mode, kitty keyboard protocol).
struct KeySpec: Identifiable {
    enum Output {
        /// A key that produces no text (arrows, Esc, Enter, Tab, PgUp ...).
        case key(PhysicalKey, KeyModifiers)
        /// A character, typed like on a US layout (so Ctrl+c encodes as 0x03).
        case text(String, KeyModifiers)
        /// Several events in a row ("esc esc", a prefix then a key).
        case sequence([Output])
    }

    var id: String
    var title: String?
    var symbol: String?
    var accessibilityLabel: String
    /// Only keys without an alternate may repeat while held (a flick needs the touch-up).
    var repeatable = false
    var output: Output
    /// What a vertical flick sends, with the small glyph shown in the key's corner.
    var alternate: Output?
    var alternateTitle: String?

    /// The events to send, with modifiers latched on the bar (sticky Ctrl/Alt) added.
    func events(latched: KeyModifiers, alternate useAlternate: Bool = false) -> [KeyEvent] {
        Self.events(useAlternate ? (alternate ?? output) : output, latched: latched)
    }

    /// The single event of a plain key (repeating keys only).
    func event(latched: KeyModifiers) -> KeyEvent {
        events(latched: latched)[0]
    }

    private static func events(_ output: Output, latched: KeyModifiers) -> [KeyEvent] {
        switch output {
        case .key(let key, let mods): [.press(key, mods: mods.union(latched))]
        case .text(let text, let mods): [.typing(text, mods: mods.union(latched))]
        // Latched modifiers apply to the first event only (a prefix key, then a plain key).
        case .sequence(let parts):
            parts.enumerated().flatMap { index, part in events(part, latched: index == 0 ? latched : []) }
        }
    }

    /// The same key with a flick alternate.
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

    static func pair(_ id: String, _ tap: String, _ flick: String, label: String) -> KeySpec {
        text(id, tap, label: label).flick(.text(flick, []), title: flick)
    }

    /// `^X / ^Y` keys.
    static func ctrlPair(_ tap: String, _ flick: String, label: String) -> KeySpec {
        ctrl(tap, label: label).flick(.text(flick, .control), title: "^\(flick.uppercased())")
    }

    static let esc = key("esc", .escape, title: "esc", label: "Escape")
    static let tab = key("tab", .tab, symbol: "arrow.right.to.line", label: "Tab")
    static let shiftTab = key("shift-tab", .tab, mods: .shift, symbol: "arrow.left.to.line", label: "Shift Tab")
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

    /// F1–F12 (HID usages 0x3A–0x45).
    static func function(_ n: Int) -> Output {
        .key(PhysicalKey(hidUsage: UInt32(0x39 + n))!, [])
    }

    static func fkey(_ n: Int, flick: String, label: String) -> KeySpec {
        KeySpec(id: "f\(n)", title: "F\(n)", accessibilityLabel: label, output: function(n))
            .flick(.text(flick, []), title: flick)
    }
}

/// (`esc ctl alt tab … ✥`) is the same everywhere. Matched by foreground program, else by title.
struct KeyBarProfile: Identifiable, Equatable {
    var id: String
    var name: String
    /// Foreground process names (basename, lowercased) that select this profile.
    var programs: Set<String>
    /// Matched against the lowercased title when the program is unknown.
    var titlePattern: String?
    /// The wing, most-used first: the first four keys are visible without scrolling on iPhone.
    var keys: [KeySpec]
    /// Agents default to the composer; shells and TUIs to direct input.
    var prefersComposer = false

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    static let shell = KeyBarProfile(
        id: "shell", name: "Shell", programs: ["bash", "zsh", "fish", "sh", "dash", "nu", "pwsh"], titlePattern: nil,
        keys: [
            .pair("tilde", "~", "$", label: "Tilde"), .pair("pipe", "|", "&", label: "Pipe"),
            .pair("dash", "-", "_", label: "Dash"), .pair("slash", "/", "\\", label: "Slash"),
            .pair("gt", ">", "<", label: "Greater than"), .pair("star", "*", "?", label: "Star"),
            .pair("eq", "=", "+", label: "Equals"), .pair("quote", "\"", "'", label: "Quote"),
            .pair("lbracket", "[", "{", label: "Left bracket"), .pair("rbracket", "]", "}", label: "Right bracket"),
            .ctrlPair("r", "s", label: "Control R, history search"), .ctrlPair("c", "z", label: "Control C"),
            .ctrlPair("d", "l", label: "Control D"), .ctrlPair("a", "e", label: "Control A, line start"),
            .ctrlPair("w", "u", label: "Control W, delete word"),
        ])

    static let vim = KeyBarProfile(
        id: "vim", name: "Vim", programs: ["vim", "nvim", "vi", "view", "vimdiff"], titlePattern: #"\bn?vim?\b"#,
        keys: [
            .pair("colon", ":", ";", label: "Colon"), .pair("slash", "/", "?", label: "Search"),
            .text("u", "u", label: "Undo").flick(.text("r", .control), title: "^R"),
            .ctrlPair("w", "o", label: "Control W, window"), .ctrlPair("d", "u", label: "Control D, half page down"),
            .ctrlPair("f", "b", label: "Control F, page down"), .pair("star", "*", "#", label: "Search word"),
            .pair("n", "n", "N", label: "Next match"), .pair("zero", "0", "$", label: "Line start"),
            .pair("g", "g", "G", label: "Go"), .pair("dot", ".", "%", label: "Repeat"),
            .ctrlPair("v", "a", label: "Control V, block select"),
        ])

    static let pager = KeyBarProfile(
        id: "pager", name: "Pager", programs: ["less", "more", "man", "most", "bat"],
        titlePattern: #"\b(less|more|man)\b"#,
        keys: [
            .pair("q", "q", "Q", label: "Quit"),
            .text("space", " ", title: "␣", label: "Space, next page").flick(.text("b", []), title: "b"),
            .pair("slash", "/", "?", label: "Search"), .pair("n", "n", "N", label: "Next match"),
            .pair("g", "g", "G", label: "Top"), .ctrlPair("d", "u", label: "Control D, half page"),
            KeySpec.pageDown.flick(.key(PhysicalKey(hidUsage: 0x4B)!, []), title: "PgUp"),
            .pair("F", "F", "&", label: "Follow"),
        ])

    static let monitor = KeyBarProfile(
        id: "monitor", name: "Monitor", programs: ["htop", "top", "btop", "glances", "atop"],
        titlePattern: #"\b(htop|top|btop|glances)\b"#,
        keys: [
            .fkey(10, flick: "q", label: "F10, quit"), .fkey(6, flick: ">", label: "F6, sort"),
            .fkey(3, flick: "/", label: "F3, search"), .fkey(4, flick: "\\", label: "F4, filter"),
            .fkey(9, flick: "k", label: "F9, kill"), .fkey(5, flick: "t", label: "F5, tree"),
            .fkey(2, flick: "S", label: "F2, setup"),
            .text("space", " ", title: "␣", label: "Space, tag").flick(.text("u", []), title: "u"),
            .pair("plus", "+", "-", label: "Expand"),
        ])

    static let tmux = KeyBarProfile(
        id: "tmux", name: "tmux", programs: ["tmux"], titlePattern: #"\btmux\b"#,
        keys: [
            .ctrlPair("b", "a", label: "Control B, tmux prefix"),
            prefixed("c", ",", label: "New window"), prefixed("n", "p", label: "Next window"),
            prefixed("%", "\"", label: "Split"), prefixed("o", ";", label: "Next pane"),
            prefixed("z", "x", label: "Zoom pane"), prefixed("[", "]", label: "Copy mode"),
            prefixed("d", "$", label: "Detach"), prefixed("w", "s", label: "Choose window"),
        ])

    static let claude = KeyBarProfile(
        id: "claude", name: "Claude Code", programs: ["claude"],
        // Claude Code titles its terminal "✳ <task>" (a spinner glyph while working).
        titlePattern: #"\bclaude\b|^[✳✻✽✶✢·]\s"#,
        keys: [
            KeySpec.shiftTab.flick(.text("t", .control), title: "^T"),
            .text("1", "1", label: "Choice 1").flick(.key(.enter, []), title: "⏎"),
            .pair("2", "2", "3", label: "Choice 2"), .pair("slash", "/", "#", label: "Slash command"),
            .pair("at", "@", "!", label: "Mention file"), .ctrlPair("c", "r", label: "Control C"),
            .ctrlPair("o", "b", label: "Control O"),
            KeySpec(id: "rewind", title: "esc²", accessibilityLabel: "Escape twice, rewind",
                    output: .sequence([.key(.escape, []), .key(.escape, [])]))
                .flick(.key(.arrowUp, []), title: "↑"),
        ],
        prefersComposer: true)

    static let codex = KeyBarProfile(
        id: "codex", name: "Codex", programs: ["codex"], titlePattern: #"\bcodex\b"#,
        keys: [
            .pair("y", "y", "n", label: "Yes, approve"), .pair("slash", "/", "@", label: "Slash command"),
            .ctrlPair("c", "j", label: "Control C"), .ctrlPair("t", "o", label: "Control T, transcript"),
            .pair("1", "1", "2", label: "Choice 1"),
            KeySpec(id: "rewind", title: "esc²", accessibilityLabel: "Escape twice, back",
                    output: .sequence([.key(.escape, []), .key(.escape, [])]))
                .flick(.key(.arrowUp, []), title: "↑"),
        ],
        prefersComposer: true)

    static let repl = KeyBarProfile(
        id: "repl", name: "REPL",
        programs: ["python", "python3", "ipython", "node", "irb", "psql", "sqlite3", "ghci", "iex", "deno", "bun"],
        titlePattern: #"\b(python3?|ipython|irb|psql|sqlite3)\b"#,
        keys: [
            .pair("lparen", "(", ")", label: "Parenthesis"), .pair("lbracket", "[", "]", label: "Bracket"),
            .pair("lbrace", "{", "}", label: "Brace"), .pair("colon", ":", ";", label: "Colon"),
            .pair("quote", "\"", "'", label: "Quote"), .pair("eq", "=", "+", label: "Equals"),
            .ctrlPair("d", "l", label: "Control D"), .ctrlPair("r", "c", label: "Control R"),
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

    /// The profile for a pane: its foreground program when known, else title heuristics, else Shell.
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
