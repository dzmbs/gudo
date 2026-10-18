import Foundation

/// A quick command (04-mobile-ux A1.8, A30): one flat list of label + body, optionally without
/// pressing Return. No folders, no templating.
struct Snippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var body: String
    /// Press Return after inserting the body ("run"); false only inserts it.
    var sendReturn: Bool
}

/// The user's snippets, persisted as JSON in `UserDefaults`.
@MainActor
final class SnippetStore {
    static let shared = SnippetStore()
    private static let key = "keyBar.snippets.v1"

    private let defaults: UserDefaults
    private(set) var snippets: [Snippet]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = saved
        } else {
            snippets = Self.defaultSnippets
        }
    }

    static let defaultSnippets = [
        Snippet(label: "git status", body: "git status", sendReturn: true),
        Snippet(label: "git diff", body: "git diff", sendReturn: true),
        Snippet(label: "ls -la", body: "ls -la", sendReturn: true),
        Snippet(label: "cd ..", body: "cd ..", sendReturn: true),
        Snippet(label: "claude", body: "claude", sendReturn: true),
        Snippet(label: "fix tests", body: "Run the tests and fix any failures.", sendReturn: false),
    ]

    func replace(_ snippets: [Snippet]) {
        self.snippets = snippets
        if let data = try? JSONEncoder().encode(snippets) { defaults.set(data, forKey: Self.key) }
    }
}
