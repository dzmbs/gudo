import Foundation
import Observation

/// Where a Files browser is, with Finder's history: the levels opened from where browsing
/// started (back), the ones gone back from (forward), and the folders around it. A leaf's
/// navigator is kept by its window, so a leaf rebuilt by a split keeps its place.
@MainActor
@Observable
final class FilesNavigator {
    enum Place: Hashable {
        case folder(String)
        case file(FileEntry)

        var path: String {
            switch self {
            case .folder(let path): path
            case .file(let entry): entry.path
            }
        }
    }

    /// The levels, where browsing started first: the last is on screen.
    private(set) var levels: [Place]
    private(set) var forwards: [Place] = []
    /// Folders open in place (disclosure triangles), across levels as in Finder.
    var expanded: Set<String> = []
    /// Folders' entries as last listed: a level gone back to shows at once, then refreshes.
    var listings: [String: [FileEntry]] = [:]

    init(root: String) {
        levels = [.folder(root)]
    }

    var place: Place { levels[levels.count - 1] }
    var canGoBack: Bool { levels.count > 1 }
    var canGoForward: Bool { !forwards.isEmpty }
    /// Nowhere yet: the start can follow the focused pane's folder.
    var isAtStart: Bool { levels.count == 1 && forwards.isEmpty }

    /// The folder shown, or the folder of the file shown.
    var folder: String {
        switch place {
        case .folder(let path): path
        case .file(let entry): Self.parent(of: entry.path) ?? entry.path
        }
    }

    func open(_ place: Place) {
        guard place != self.place else { return }
        levels.append(place)
        forwards.removeAll()
    }

    func goBack() {
        guard canGoBack else { return }
        forwards.append(levels.removeLast())
    }

    func goForward() {
        guard let next = forwards.popLast() else { return }
        levels.append(next)
    }

    /// The enclosing folder (⌘↑): back when that is where this level was opened from.
    func openEnclosing() {
        guard let parent = enclosing else { return }
        go(to: parent)
    }

    /// An enclosing folder from the path bar or the title's menu: back to it when it is a level
    /// already open, else a new level.
    func go(to folder: String) {
        if let index = levels.lastIndex(of: .folder(folder)), index < levels.count - 1 {
            forwards.append(contentsOf: levels[(index + 1)...].reversed())
            levels.removeSubrange((index + 1)...)
        } else {
            open(.folder(folder))
        }
    }

    /// Starts over at `root` (the focused pane's folder changed before anything was opened).
    func reset(to root: String) {
        levels = [.folder(root)]
        forwards.removeAll()
    }

    /// For a NavigationStack: the levels above the first.
    var stack: [Place] {
        get { Array(levels.dropFirst()) }
        set {
            let kept = [levels[0]] + newValue
            if kept.count < levels.count, Array(levels.prefix(kept.count)) == kept {
                forwards.append(contentsOf: levels[kept.count...].reversed())
            } else {
                forwards.removeAll()
            }
            levels = kept
        }
    }

    var enclosing: String? {
        if case .file = place { return folder }
        return Self.parent(of: folder)
    }

    /// The folders from the top of the file system (or home) down to the one shown.
    var trail: [String] { Self.ancestors(of: folder) }

    nonisolated static func parent(of path: String) -> String? {
        guard path != "/", path != "~", !path.isEmpty else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    /// `/a/b` → `/`, `/a`, `/a/b`; `~/a` → `~`, `~/a`.
    nonisolated static func ancestors(of path: String) -> [String] {
        var chain = [path]
        while let parent = parent(of: chain[0]) { chain.insert(parent, at: 0) }
        return chain
    }
}
