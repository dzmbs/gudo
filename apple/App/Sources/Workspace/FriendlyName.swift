import Foundation

/// Short, friendly tab names ("quiet-otter"), given to every new tab so tabs are easy to tell
/// apart and to talk about. The words are curated: calm, neutral, easy to say and to spell, no
/// two that read as a phrase with a second meaning.
enum FriendlyName {
    static let adjectives = [
        "amber", "brisk", "calm", "clear", "coral", "crisp", "dusky", "early", "fern", "gentle",
        "golden", "hazel", "humble", "ivory", "jade", "keen", "lucid", "mellow", "misty", "nimble",
        "noble", "olive", "pale", "plucky", "polar", "quiet", "rapid", "rosy", "rustic", "sage",
        "silver", "sleek", "snowy", "solar", "steady", "still", "sunny", "swift", "tidy", "velvet",
        "vivid", "warm", "wild", "windy", "witty", "young", "zesty", "bright",
    ]

    static let nouns = [
        "otter", "heron", "maple", "harbor", "comet", "falcon", "willow", "badger", "lagoon", "cedar",
        "puffin", "meadow", "lynx", "pebble", "orchid", "sparrow", "canyon", "walrus", "aspen", "beacon",
        "marten", "glacier", "finch", "tundra", "bison", "coyote", "delta", "ember", "fjord", "gecko",
        "island", "koala", "lantern", "magpie", "nebula", "osprey", "panda", "quartz", "raven", "summit",
        "tiger", "valley", "wren", "yak", "zephyr", "acorn", "brook", "pine",
    ]

    /// A new name, avoiding the ones in use when it can.
    static func make(avoiding used: Set<String> = []) -> String {
        for _ in 0..<12 {
            let name = "\(adjectives.randomElement()!)-\(nouns.randomElement()!)"
            if !used.contains(name) { return name }
        }
        return "\(adjectives.randomElement()!)-\(nouns.randomElement()!)"
    }

    /// Whether a tab title is one of ours (so a shell title may replace it when the user asked
    /// for titles from the shell), rather than the user's own rename.
    static func isGenerated(_ title: String) -> Bool {
        let parts = title.split(separator: "-", maxSplits: 1).map(String.init)
        return parts.count == 2 && adjectives.contains(parts[0]) && nouns.contains(parts[1])
    }
}

/// The `repo:branch` of a directory's git checkout, read from `.git/HEAD` (no git process), cached
/// per directory.
enum GitContext {
    @MainActor private static var cache: [String: (String?, Date)] = [:]

    @MainActor
    static func repoBranch(at directory: String) -> String? {
        if let (value, time) = cache[directory], Date().timeIntervalSince(time) < 5 { return value }
        let value = read(directory)
        cache[directory] = (value, Date())
        return value
    }

    private static func read(_ directory: String) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true)
        for _ in 0..<24 {
            let dotGit = url.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var head = dotGit.appending(path: "HEAD")
                if !isDirectory.boolValue,
                   let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                   let path = pointer.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
                {
                    // A worktree or submodule: `.git` is a file naming the real git directory.
                    head = URL(fileURLWithPath: path, relativeTo: url).appending(path: "HEAD")
                }
                guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
                let ref = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let branch = ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst("ref: refs/heads/".count)) : String(ref.prefix(7))
                return "\(url.lastPathComponent):\(branch)"
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}
