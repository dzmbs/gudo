import Foundation

/// What a file's menus copy: its contents, its path, and its path inside the repository holding it.
struct FileCopyAction: Identifiable, Equatable {
    enum Kind {
        case contents, path, relativePath, pathWithLine
    }

    var kind: Kind
    var text: String

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .contents: "Copy File Contents"
        case .path: "Copy Path"
        case .relativePath: "Copy Relative Path"
        case .pathWithLine: "Copy Path and Line"
        }
    }

    var systemImage: String {
        switch kind {
        case .contents: "doc.on.clipboard"
        case .path: "doc.on.doc"
        case .relativePath: "arrow.turn.down.right"
        case .pathWithLine: "number"
        }
    }

    /// The actions in menu order. `contents` is nil for a folder or a file not shown as text;
    /// `repositoryRoot` is nil outside a repository; `resolvedPath` is the path as the host spells
    /// it (`~` expanded), when known.
    static func actions(
        path: String, resolvedPath: String? = nil, line: Int? = nil, column: Int? = nil, contents: String?, repositoryRoot: String?
    ) -> [FileCopyAction] {
        var actions: [FileCopyAction] = []
        if let contents { actions.append(FileCopyAction(kind: .contents, text: contents)) }
        actions.append(FileCopyAction(kind: .path, text: path))
        if let repositoryRoot, let relative = RepositoryPath.relative(resolvedPath ?? path, root: repositoryRoot) {
            actions.append(FileCopyAction(kind: .relativePath, text: relative))
        }
        if let line {
            actions.append(FileCopyAction(kind: .pathWithLine, text: "\(path):\(line)" + (column.map { ":\($0)" } ?? "")))
        }
        return actions
    }
}

enum RepositoryPath {
    /// `path` from `root` ("src/main.rs"), nil when it is not inside it or is the root itself.
    static func relative(_ path: String, root: String) -> String? {
        let path = PathMatch.normalized(path), root = PathMatch.normalized(root)
        guard path.hasPrefix(root + "/") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        return relative.isEmpty ? nil : relative
    }

    /// The nearest folder at or above `folder` on this device that holds a `.git`.
    nonisolated static func localRoot(of folder: String) -> String? {
        var url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }
}
