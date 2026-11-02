import Foundation
@testable import FilesProviderKit
import GudoCore

nonisolated func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "filesprovider-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // The canonical spelling (/private/var), as a daemon reports paths.
    return url.resolvingSymlinksInPath()
}

/// The daemon's file RPCs over a local folder, with its semantics: `~` is the folder, versions
/// are `inode-size-mtime_ns`, renames never replace, `if_match` and `create_new` are checked,
/// deletes go to a trash folder outside the home.
nonisolated final class LocalFileSystem: RemoteFileSystem, @unchecked Sendable {
    let home: URL
    let trash: URL
    private let fileManager = FileManager.default

    init() {
        let root = temporaryDirectory()
        home = root.appending(path: "home")
        trash = root.appending(path: "trash")
        try? fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func resolve(_ path: String) -> String {
        path == "~" ? home.path : path.hasPrefix("~/") ? home.path + path.dropFirst(1) : path
    }

    func stat(_ path: String) throws -> FileStat {
        let path = resolve(path)
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { throw WorkspaceError.NotFound(message: path) }
        let kind: FileKind = switch info.st_mode & S_IFMT {
        case S_IFDIR: .dir
        case S_IFREG: .file
        case S_IFLNK: .symlink
        default: .other
        }
        var targetKind: FileKind?
        var linkTarget: String?
        if kind == .symlink {
            linkTarget = try? fileManager.destinationOfSymbolicLink(atPath: path)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) { targetKind = isDirectory.boolValue ? .dir : .file }
        }
        let mtimeNs = UInt64(info.st_mtimespec.tv_sec) * 1_000_000_000 + UInt64(info.st_mtimespec.tv_nsec)
        let name = (path as NSString).lastPathComponent
        return FileStat(
            path: path, name: name, kind: kind, size: UInt64(info.st_size), modifiedMs: mtimeNs / 1_000_000,
            mode: UInt32(info.st_mode & 0o7777), hidden: name.hasPrefix("."), linkTarget: linkTarget, targetKind: targetKind,
            version: "\(info.st_ino)-\(info.st_size)-\(mtimeNs)")
    }

    func fsList(path: String, showHidden: Bool) async throws -> DirListing {
        let path = resolve(path)
        guard try stat(path).kind == .dir || stat(path).targetKind == .dir else { throw WorkspaceError.Invalid(message: "not a directory") }
        let names = try fileManager.contentsOfDirectory(atPath: path).sorted()
        let entries = try names.filter { showHidden || !$0.hasPrefix(".") }.map { try stat(RemotePath.join(path, $0)) }
        return DirListing(path: path, entries: entries, truncated: false)
    }

    func fsStat(path: String) async throws -> FileStat { try stat(path) }

    func fsMkdir(path: String, parents: Bool) async throws -> FileStat {
        if fileManager.fileExists(atPath: path) { throw WorkspaceError.Conflict(message: "exists") }
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: parents)
        return try stat(path)
    }

    func fsRename(from: String, to: String, overwrite: Bool) async throws -> FileStat {
        guard fileManager.fileExists(atPath: from) else { throw WorkspaceError.NotFound(message: from) }
        if fileManager.fileExists(atPath: to), !overwrite { throw WorkspaceError.Conflict(message: "exists") }
        try fileManager.moveItem(atPath: from, toPath: to)
        return try stat(to)
    }

    func fsDelete(path: String, mode: DeleteMode, recursive: Bool) async throws {
        guard fileManager.fileExists(atPath: path) else { throw WorkspaceError.NotFound(message: path) }
        if mode == .trash {
            try fileManager.moveItem(atPath: path, toPath: trash.appending(path: UUID().uuidString).path)
        } else {
            try fileManager.removeItem(atPath: path)
        }
    }

    func uploadFile(localPath: String, target: WriteTarget, progress: TransferProgress?) async throws -> FileStat {
        let exists = fileManager.fileExists(atPath: target.path)
        if target.createNew, exists { throw WorkspaceError.Conflict(message: "exists") }
        if let ifMatch = target.ifMatch, (try? stat(target.path).version) != ifMatch {
            throw WorkspaceError.Conflict(message: "changed")
        }
        // As the daemon does: a temporary file renamed over the target (a new inode).
        let temporary = RemotePath.join(RemotePath.parent(target.path), ".upload-\(UUID().uuidString)")
        try fileManager.copyItem(atPath: localPath, toPath: temporary)
        if exists { try fileManager.removeItem(atPath: target.path) }
        try fileManager.moveItem(atPath: temporary, toPath: target.path)
        return try stat(target.path)
    }

    func downloadFile(remotePath: String, localPath: String, offset: UInt64, len: UInt64?, progress: TransferProgress?) async throws -> FileStat {
        let stat = try stat(remotePath)
        try fileManager.copyItem(atPath: remotePath, toPath: localPath)
        return stat
    }
}
