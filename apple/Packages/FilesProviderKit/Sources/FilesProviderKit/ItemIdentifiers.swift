import Foundation
import Synchronization

/// Stable item identifiers for remote paths. The system wants an item to keep its identifier
/// through renames and moves, and the daemon has no file ids that survive its own writes (an
/// upload is a new inode), so identifiers are minted here and mapped to paths: a rename or
/// move made through Files keeps the identifier, a change made on the host reads as a delete
/// and a create. Saved as JSON so identifiers outlive the extension's process.
nonisolated public final class ItemIdentifiers: Sendable {
    private struct Saved: Codable {
        var paths: [String: String] = [:]
        /// Directories listed lately, newest last: what the working set keeps current.
        var visited: [String] = []
    }

    private struct State {
        var saved: Saved
        var ids: [String: String]

        init(_ saved: Saved) {
            self.saved = saved
            ids = Dictionary(saved.paths.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        }

        mutating func rebuild() {
            ids = Dictionary(saved.paths.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Directories the working set follows.
    static let visitedLimit = 64

    private let file: URL?
    private let state: Mutex<State>

    /// - Parameter file: where to keep the map; nil keeps it in memory.
    public init(file: URL?) {
        self.file = file
        let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        state = Mutex(State(saved ?? Saved()))
    }

    /// The path's identifier, minted on first sight.
    public func identifier(for path: String) -> String {
        let (id, minted) = state.withLock { state -> (String, Bool) in
            if let id = state.ids[path] { return (id, false) }
            let id = UUID().uuidString
            state.saved.paths[id] = path
            state.ids[path] = id
            return (id, true)
        }
        if minted { save() }
        return id
    }

    public func path(for identifier: String) -> String? {
        state.withLock { $0.saved.paths[identifier] }
    }

    /// A rename or move: the item and everything under it keep their identifiers.
    public func moved(from old: String, to new: String) {
        state.withLock { state in
            for (id, path) in state.saved.paths where RemotePath.isWithin(path, old) {
                state.saved.paths[id] = new + path.dropFirst(old.count)
            }
            state.saved.visited = state.saved.visited.map {
                RemotePath.isWithin($0, old) ? new + $0.dropFirst(old.count) : $0
            }
            state.rebuild()
        }
        save()
    }

    /// The item and everything under it are gone.
    public func removed(_ path: String) {
        state.withLock { state in
            state.saved.paths = state.saved.paths.filter { !RemotePath.isWithin($0.value, path) }
            state.saved.visited.removeAll { RemotePath.isWithin($0, path) }
            state.rebuild()
        }
        save()
    }

    /// A directory was listed.
    public func visited(_ directory: String) {
        let changed = state.withLock { state in
            guard state.saved.visited.last != directory else { return false }
            state.saved.visited.removeAll { $0 == directory }
            state.saved.visited.append(directory)
            let excess = state.saved.visited.count - Self.visitedLimit
            if excess > 0 { state.saved.visited.removeFirst(excess) }
            return true
        }
        if changed { save() }
    }

    /// Directories listed lately, newest first.
    public var visitedDirectories: [String] {
        state.withLock { $0.saved.visited.reversed() }
    }

    private func save() {
        guard let file else { return }
        let data = state.withLock { try? JSONEncoder().encode($0.saved) }
        try? data?.write(to: file, options: .atomic)
    }
}
