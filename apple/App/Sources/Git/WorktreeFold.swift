import Foundation
import HostKit

/// A repository section's worktrees split the way the sidebar draws them: the ones with tabs
/// here, then the rest behind one "N more worktrees" row.
struct WorktreeFold: Equatable {
    var shown: [RepoSidebar.Worktree]
    var folded: [RepoSidebar.Worktree]

    init(_ repo: RepoSidebar.Repo) {
        shown = repo.worktrees.filter { !$0.tabs.isEmpty }
        folded = repo.worktrees.filter(\.tabs.isEmpty)
    }

    var foldedTitle: String {
        folded.count == 1 ? "1 more worktree" : "\(folded.count) more worktrees"
    }
}

/// The repository sections whose folded worktrees are open, remembered on this device.
@MainActor
@Observable
final class WorktreeFoldStore {
    static let shared = WorktreeFoldStore(defaults: LaunchOptions.mock ? UserDefaults(suiteName: "mock-worktree-folds") ?? .standard : .standard)
    static let key = "sidebar.expandedWorktreeFolds"

    private(set) var expanded: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        expanded = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isExpanded(repo: String, host: String) -> Bool {
        expanded.contains(Self.id(repo: repo, host: host))
    }

    func toggle(repo: String, host: String) {
        let id = Self.id(repo: repo, host: host)
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        defaults.set(expanded.sorted(), forKey: Self.key)
    }

    private static func id(repo: String, host: String) -> String { "\(host)\n\(repo)" }
}
