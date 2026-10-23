import Foundation
import UnnamedCore

/// The daemon's file RPCs the provider uses (docs/DAEMON.md §5.6–5.7). `DaemonClient` conforms
/// as is; tests use a local folder.
nonisolated public protocol RemoteFileSystem: AnyObject, Sendable {
    func fsList(path: String, showHidden: Bool) async throws -> DirListing
    func fsStat(path: String) async throws -> FileStat
    func fsMkdir(path: String, parents: Bool) async throws -> FileStat
    func fsRename(from: String, to: String, overwrite: Bool) async throws -> FileStat
    func fsDelete(path: String, mode: DeleteMode, recursive: Bool) async throws
    func uploadFile(localPath: String, target: WriteTarget, progress: TransferProgress?) async throws -> FileStat
    func downloadFile(remotePath: String, localPath: String, offset: UInt64, len: UInt64?, progress: TransferProgress?) async throws -> FileStat
}

extension DaemonClient: RemoteFileSystem {}

/// Remote paths, always `/`-separated whatever the device.
nonisolated enum RemotePath {
    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// Whether `path` is `ancestor` or lies under it.
    static func isWithin(_ path: String, _ ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }
}
