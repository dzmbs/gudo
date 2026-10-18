import Foundation
import TerminalCore

/// What the key bar knows about the focused pane: the foreground program when the backend reports
/// it (daemon: `tcgetpgrp`), else only the terminal title (OSC 0/2).
struct KeyBarContext: Equatable {
    var program: String?
    var title: String
}

/// One key-bar key (04-mobile-ux A1.1/A1.2): a flat, one-tap key that produces exactly one key
/// event. Built from a key or a character plus modifiers, never from raw escape strings, so it
/// goes through the terminal's encoder (application-cursor mode, kitty keyboard protocol).
struct KeySpec: Identifiable {
    enum Output {
        /// A key that produces no text (arrows, Esc, Enter, Tab, PgUp ...).
        case key(PhysicalKey, KeyModifiers)
        /// A character, typed like on a US layout (so Ctrl+c encodes as 0x03).
        case text(String, KeyModifiers)
    }

    var id: String
    var title: String?
    var symbol: String?
    var accessibilityLabel: String
    /// Only arrows, Backspace, Delete and paging repeat while held (A1.4).
    var repeatable = false
    var output: Output

    /// The event to send, with modifiers latched on the bar (sticky Ctrl) added.
    func event(latched: KeyModifiers) -> KeyEvent {
        switch output {
        case .key(let key, let mods): .press(key, mods: mods.union(latched))
        case .text(let text, let mods): .typing(text, mods: mods.union(latched))
        }
    }
}

extension KeySpec {
    static func key(_ id: String, _ key: PhysicalKey, mods: KeyModifiers = [], title: String? = nil, symbol: String? = nil, label: String, repeatable: Bool = false) -> KeySpec {
        KeySpec(id: id, title: title, symbol: symbol, accessibilityLabel: label, repeatable: repeatable, output: .key(key, mods))
    }

    static func text(_ id: String, _ text: String, mods: KeyModifiers = [], title: String? = nil, label: String) -> KeySpec {
        KeySpec(id: id, title: title ?? text, accessibilityLabel: label, output: .text(text, mods))
    }

    /// Ctrl+letter as a direct key ("^C"); never repeats (A1.4: destructive keys don't).
    static func ctrl(_ letter: String, label: String) -> KeySpec {
        .text("ctrl-\(letter)", letter, mods: .control, title: "^\(letter.uppercased())", label: label)
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
    static let pageUp = key("pgup", PhysicalKey(hidUsage: 0x4B)!, title: "PgUp", label: "Page up", repeatable: true)
    static let pageDown = key("pgdn", PhysicalKey(hidUsage: 0x4E)!, title: "PgDn", label: "Page down", repeatable: true)
}

/// A context-aware key set (04-mobile-ux C5). Profiles are data: the built-ins below, matched by
/// foreground program name first and by terminal title otherwise.
struct KeyBarProfile: Identifiable, Equatable {
    var id: String
    var name: String
    /// Foreground process names (basename, lowercased) that select this profile.
    var programs: Set<String>
    /// Matched against the lowercased title when the program is unknown.
    var titlePattern: String?
    var keys: [KeySpec]
    /// Whether the sticky Ctrl key appears (after the leading keys).
    var showsCtrl: Bool
    /// How many keys come before Ctrl.
    var ctrlPosition = 2
    /// Agents default to the composer (C5); shells and TUIs to direct input.
    var prefersComposer = false

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    static let shell = KeyBarProfile(
        id: "shell", name: "Shell", programs: ["bash", "zsh", "fish", "sh", "dash", "nu", "pwsh"], titlePattern: nil,
        keys: [
            .esc, .tab, .up, .down, .left, .right,
            .ctrl("c", label: "Control C"), .ctrl("r", label: "Control R"), .ctrl("d", label: "Control D"),
            .text("tilde", "~", label: "Tilde"), .text("pipe", "|", label: "Pipe"),
            .text("dash", "-", label: "Dash"), .text("slash", "/", label: "Slash"),
        ],
        showsCtrl: true)

    static let claude = KeyBarProfile(
        id: "claude", name: "Claude Code", programs: ["claude"],
        // Claude Code titles its terminal "✳ <task>" (a spinner glyph while working).
        titlePattern: #"\bclaude\b|^[✳✻✽✶✢·]\s"#,
        keys: [
            .key("esc", .escape, title: "esc", label: "Escape, interrupt"), .shiftTab, .up, .down, .enter,
            .text("1", "1", label: "Choice 1"), .text("2", "2", label: "Choice 2"), .text("3", "3", label: "Choice 3"),
            .text("slash", "/", label: "Slash command"), .text("at", "@", label: "Mention file"),
            .ctrl("c", label: "Control C"), .ctrl("r", label: "Control R, transcript"),
        ],
        showsCtrl: false, prefersComposer: true)

    static let codex = KeyBarProfile(
        id: "codex", name: "Codex", programs: ["codex"], titlePattern: #"\bcodex\b"#,
        keys: [
            .esc, .up, .down, .enter,
            .text("y", "y", label: "Yes, approve"), .text("n", "n", label: "No, deny"),
            .text("slash", "/", label: "Slash command"), .text("at", "@", label: "Mention file"),
            .ctrl("c", label: "Control C"), .ctrl("j", label: "Control J, newline"),
        ],
        showsCtrl: false, prefersComposer: true)

    static let vim = KeyBarProfile(
        id: "vim", name: "Vim", programs: ["vim", "nvim", "vi", "view", "vimdiff"], titlePattern: #"\bn?vim?\b"#,
        keys: [
            .esc, .text("colon", ":", label: "Colon"), .up, .down, .left, .right,
            .text("u", "u", label: "Undo"), .ctrl("r", label: "Control R, redo"),
            .text("slash", "/", label: "Search"), .ctrl("w", label: "Control W, window"),
        ],
        showsCtrl: true, ctrlPosition: 2)

    static let pager = KeyBarProfile(
        id: "pager", name: "Pager", programs: ["less", "more", "man", "most", "htop", "top", "btop", "bat"],
        titlePattern: #"\b(less|more|man|htop|top|btop)\b"#,
        keys: [
            .text("q", "q", label: "Quit"), .text("space", " ", title: "space", label: "Space, next page"),
            .text("b", "b", label: "Back a page"), .text("slash", "/", label: "Search"), .text("n", "n", label: "Next match"),
            .pageUp, .pageDown, .up, .down,
        ],
        showsCtrl: false)

    /// Built-in profiles, most specific first; `shell` is the fallback.
    static let builtIn: [KeyBarProfile] = [.claude, .codex, .vim, .pager, .shell]

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
