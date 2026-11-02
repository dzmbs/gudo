import Foundation
import Observation

/// Where a Files browser is, with Finder-style back and forward. The window keeps a leaf's
/// navigator, so a leaf rebuilt by a split keeps its place.
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

    /// Where browsing started first; the last is on screen.
    private(set) var levels: [Place]
    private(set) var forwards: [Place] = []
    /// Folders open in place with disclosure triangles, across levels.
    var expanded: Set<String> = []
    /// A level gone back to shows these at once, then refreshes.
    var listings: [String: [FileEntry]] = [:]

    init(root: String) {
        levels = [.folder(root)]
    }

    var place: Place { levels[levels.count - 1] }
    var canGoBack: Bool { levels.count > 1 }
    var canGoForward: Bool { !forwards.isEmpty }
    /// The start can still follow the focused pane's folder.
    var isAtStart: Bool { levels.count == 1 && forwards.isEmpty }

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

    func openEnclosing() {
        guard let parent = enclosing else { return }
        go(to: parent)
    }

    /// Back to the folder when it is a level already open, else a new level.
    func go(to folder: String) {
        if let index = levels.lastIndex(of: .folder(folder)), index < levels.count - 1 {
            forwards.append(contentsOf: levels[(index + 1)...].reversed())
            levels.removeSubrange((index + 1)...)
        } else {
            open(.folder(folder))
        }
    }

    func reset(to root: String) {
        levels = [.folder(root)]
        forwards.removeAll()
    }

    /// For a NavigationStack.
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
