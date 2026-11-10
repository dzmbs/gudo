import Foundation
import TerminalCore

/// Every key the keys panel offers, grouped, and the ones the bar shows by default.
enum KeyCatalog {
    struct Group: Identifiable {
        var id: String
        var title: String
        var keys: [KeySpec]
    }

    static let interrupt = KeySpec.ctrl("c", label: "Control C, interrupt").captioned("Interrupt")

    static let groups: [Group] = [
        Group(id: "control", title: "Control", keys: [
            interrupt,
            .ctrl("d", label: "Control D, end of input").captioned("End input"),
            .ctrl("z", label: "Control Z, suspend").captioned("Suspend"),
            .ctrl("l", label: "Control L, clear screen").captioned("Clear"),
            .ctrl("r", label: "Control R, search history").captioned("History"),
            .ctrl("a", label: "Control A, start of line").captioned("Line start"),
            .ctrl("e", label: "Control E, end of line").captioned("Line end"),
            .ctrl("u", label: "Control U, delete line").captioned("Delete line"),
            .ctrl("k", label: "Control K, delete to end").captioned("Delete to end"),
            .ctrl("w", label: "Control W, delete word").captioned("Delete word"),
            .ctrl("o", label: "Control O").captioned("Expand"),
            .ctrl("b", label: "Control B, tmux prefix").captioned("tmux"),
        ]),
        Group(id: "keys", title: "Keys", keys: [
            KeySpec.esc.captioned("Escape"),
            KeySpec.tab.captioned("Tab"),
            KeySpec.shiftTab.captioned("Shift Tab"),
            KeySpec.enter.captioned("Enter"),
            KeySpec.backspace.captioned("Delete"),
            .key("forward-delete", PhysicalKey(hidUsage: 0x4C)!, symbol: "delete.right", label: "Forward delete", repeatable: true)
                .captioned("Fwd delete"),
            KeySpec.paste.captioned("Paste"),
        ]),
        Group(id: "agents", title: "Coding Agents", keys: [
            KeySpec.mode.captioned("Mode"),
            KeySpec.newline.captioned("New line"),
            KeySpec.rewind.captioned("Rewind"),
        ]),
        Group(id: "navigation", title: "Navigation", keys: [
            KeySpec.left, .down, .up, .right,
            .key("word-left", .arrowLeft, mods: .alt, title: "⌥←", label: "Option left, word left").captioned("Word left"),
            .key("word-right", .arrowRight, mods: .alt, title: "⌥→", label: "Option right, word right").captioned("Word right"),
            KeySpec.home, .end, .pageUp, .pageDown,
        ]),
        Group(id: "symbols", title: "Symbols", keys: [
            .pair("tilde", "~", "$", label: "Tilde"), .pair("pipe", "|", "&", label: "Vertical bar"),
            .pair("slash", "/", "\\", label: "Slash"), .text("backslash", "\\", label: "Backslash"),
            .pair("dash", "-", "_", label: "Hyphen"), .text("underscore", "_", label: "Underscore"),
            .pair("backtick", "`", "'", label: "Backtick"), .text("quote", "'", label: "Quote"),
            .text("double-quote", "\"", label: "Double quote"), .pair("star", "*", "?", label: "Star"),
            .text("question", "?", label: "Question mark"), .text("bang", "!", label: "Exclamation mark"),
            .text("at", "@", label: "At"), .text("hash", "#", label: "Hash"),
            .pair("dollar", "$", "#", label: "Dollar"), .text("percent", "%", label: "Percent"),
            .text("caret", "^", label: "Caret"), .text("ampersand", "&", label: "Ampersand"),
            .text("equals", "=", label: "Equals"), .text("plus", "+", label: "Plus"),
            .text("colon", ":", label: "Colon"), .text("semicolon", ";", label: "Semicolon"),
            .text("lt", "<", label: "Less than"), .pair("gt", ">", "<", label: "Greater than"),
            .text("lparen", "(", label: "Left parenthesis"), .text("rparen", ")", label: "Right parenthesis"),
            .text("lbracket", "[", label: "Left bracket"), .text("rbracket", "]", label: "Right bracket"),
            .text("lbrace", "{", label: "Left brace"), .text("rbrace", "}", label: "Right brace"),
        ]),
        Group(id: "function", title: "Function Keys", keys: (1...12).map { number in
            KeySpec(id: "f\(number)", title: "F\(number)", accessibilityLabel: "F\(number)", output: KeySpec.function(number))
        }),
    ]

    private static let byID: [String: KeySpec] = Dictionary(
        groups.flatMap(\.keys).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static func key(id: String) -> KeySpec? { byID[id] }

    /// Pinned at the bar's start in every profile, beside `ctrl`; not part of the favourites.
    static let pinnedIDs: Set<String> = ["esc", "tab", "enter"]

    /// The bar's keys after the pinned ones until the user picks their own: the arrows, then
    /// interrupt, then what a shell and coding agents type most.
    static let defaultFavourites = [
        "up", "down", "left", "right", "ctrl-c",
        "pipe", "slash", "tilde", "dash", "ctrl-r", "ctrl-d", "ctrl-z", "ctrl-l",
        "backtick", "star", "dollar", "gt", "backslash", "paste",
    ]
}

/// The keys the user keeps in the bar, in order; saved on this device.
@MainActor
final class FavouriteKeys {
    static let shared = FavouriteKeys()
    static let storageKey = "keyBar.favourites.v2"
    /// Saved while ^C was pinned and Enter was not.
    static let previousStorageKey = "keyBar.favourites.v1"
    static let previousDefaults = [
        "tilde", "pipe", "slash", "dash", "ctrl-r", "ctrl-d", "ctrl-z", "ctrl-l",
        "backtick", "star", "dollar", "gt", "backslash", "paste",
    ]

    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrate()
    }

    /// A list the user made keeps its keys, with ^C first where it was pinned; the old defaults
    /// give way to the new ones.
    private func migrate() {
        guard defaults.object(forKey: Self.storageKey) == nil,
              let previous = defaults.stringArray(forKey: Self.previousStorageKey),
              previous != Self.previousDefaults else { return }
        let kept = previous.filter { !KeyCatalog.pinnedIDs.contains($0) && $0 != KeyCatalog.interrupt.id }
        defaults.set([KeyCatalog.interrupt.id] + kept, forKey: Self.storageKey)
    }

    var ids: [String] {
        get {
            guard let stored = defaults.stringArray(forKey: Self.storageKey) else { return KeyCatalog.defaultFavourites }
            return stored.filter { KeyCatalog.key(id: $0) != nil && !KeyCatalog.pinnedIDs.contains($0) }
        }
        set {
            var seen = Set<String>()
            let cleaned = newValue.filter { KeyCatalog.key(id: $0) != nil && !KeyCatalog.pinnedIDs.contains($0) && seen.insert($0).inserted }
            guard cleaned != ids || defaults.object(forKey: Self.storageKey) == nil else { return }
            defaults.set(cleaned, forKey: Self.storageKey)
            onChange?()
        }
    }

    var keys: [KeySpec] { ids.compactMap(KeyCatalog.key(id:)) }

    var isDefault: Bool { ids == KeyCatalog.defaultFavourites }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if contains(id) {
            ids.removeAll { $0 == id }
        } else {
            ids.append(id)
        }
    }

    func move(from source: Int, to destination: Int) {
        var list = ids
        guard list.indices.contains(source) else { return }
        let id = list.remove(at: source)
        list.insert(id, at: min(max(0, destination), list.count))
        ids = list
    }

    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.previousStorageKey)
        onChange?()
    }
}
