import FileProvider
import Foundation
import Synchronization
import UniformTypeIdentifiers
import GudoCore

/// One host's files for the File Provider extension: the home directory is the root, items
/// carry identifiers from `ItemIdentifiers`, and every change goes through the daemon's file
/// RPCs. Errors come out as the File Provider errors Files understands.
nonisolated public final class FilesProviderCore: Sendable {
    /// What a modification touches.
    public struct Changes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let contents = Changes(rawValue: 1 << 0)
        public static let filename = Changes(rawValue: 1 << 1)
        public static let parent = Changes(rawValue: 1 << 2)
    }

    public let identifiers: ItemIdentifiers
    private let remote: any RemoteFileSystem
    private let downloads: URL
    private let home = Mutex<String?>(nil)
    /// A container whose listing changed by more than the item asked about (a conflict copy).
    private let onContainerChanged: @Sendable (NSFileProviderItemIdentifier) -> Void

    /// - Parameters:
    ///   - downloads: where fetched contents go (the system moves them into place).
    ///   - onContainerChanged: a listing changed beyond the item an operation returned.
    public init(
        remote: any RemoteFileSystem, identifiers: ItemIdentifiers, downloads: URL,
        onContainerChanged: @escaping @Sendable (NSFileProviderItemIdentifier) -> Void = { _ in }
    ) {
        self.remote = remote
        self.identifiers = identifiers
        self.downloads = downloads
        self.onContainerChanged = onContainerChanged
    }

    // MARK: Paths and items

    /// The host's home directory: the domain's root.
    public func homePath() async throws -> String {
        if let path = home.withLock({ $0 }) { return path }
        let stat = try await mapped { try await self.remote.fsStat(path: "~") }
        home.withLock { $0 = stat.path }
        return stat.path
    }

    public func path(of identifier: NSFileProviderItemIdentifier) async throws -> String {
        let home = try await homePath()
        if identifier == .rootContainer { return home }
        guard let path = identifiers.path(for: identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
        return path
    }

    func identifier(for path: String, home: String) -> NSFileProviderItemIdentifier {
        path == home ? .rootContainer : NSFileProviderItemIdentifier(identifiers.identifier(for: path))
    }

    func item(_ stat: FileStat, at path: String) async throws -> RemoteItem {
        let home = try await homePath()
        let parent = path == home ? NSFileProviderItemIdentifier.rootContainer : identifier(for: RemotePath.parent(path), home: home)
        guard let item = RemoteItem(stat, path: path, identifier: identifier(for: path, home: home), parent: parent) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return item
    }

    public func item(for identifier: NSFileProviderItemIdentifier) async throws -> RemoteItem {
        guard identifier != .workingSet, identifier != .trashContainer else { throw NSFileProviderError(.noSuchItem) }
        let path = try await path(of: identifier)
        let stat = try await mapped { try await self.remote.fsStat(path: path) }
        return try await item(stat, at: path)
    }

    // MARK: Enumeration

    /// A folder's items, hidden ones included (flagged hidden).
    public func children(of container: NSFileProviderItemIdentifier) async throws -> [RemoteItem] {
        if container == .workingSet { return try await workingSet() }
        guard container != .trashContainer else { return [] }
        let directory = try await path(of: container)
        let listing = try await mapped { try await self.remote.fsList(path: directory, showHidden: true) }
        identifiers.visited(directory)
        var items: [RemoteItem] = []
        for stat in listing.entries {
            // The name under the asked spelling, so children keep their parent's identifier.
            if let item = try? await item(stat, at: RemotePath.join(directory, stat.name)) { items.append(item) }
        }
        return items
    }

    /// What Files keeps current without being asked: the folders listed lately and what is in
    /// them. A folder that is gone leaves the set.
    public func workingSet() async throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        for directory in identifiers.visitedDirectories {
            do {
                let listing = try await mapped { try await self.remote.fsList(path: directory, showHidden: true) }
                for stat in listing.entries {
                    if let item = try? await item(stat, at: RemotePath.join(directory, stat.name)) { items.append(item) }
                }
            } catch let error as NSFileProviderError where error.code == .noSuchItem {
                identifiers.removed(directory)
            }
        }
        return items
    }

    // MARK: Contents

    /// Downloads a file; the system takes the file at the returned URL.
    public func fetchContents(of identifier: NSFileProviderItemIdentifier) async throws -> (URL, RemoteItem) {
        let path = try await path(of: identifier)
        let folder = downloads.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local = folder.appending(path: (path as NSString).lastPathComponent)
        let stat = try await mapped {
            try await self.remote.downloadFile(remotePath: path, localPath: local.path, offset: 0, len: nil, progress: nil)
        }
        return (local, try await item(stat, at: path))
    }

    // MARK: Changes

    /// A new folder or file. `mayAlreadyExist`: the system is re-creating what it knew (after a
    /// reinstall); an existing item of that name is then the answer, not a collision.
    public func create(
        name: String, in parent: NSFileProviderItemIdentifier, isFolder: Bool, contents: URL?, mayAlreadyExist: Bool = false
    ) async throws -> RemoteItem {
        let path = RemotePath.join(try await self.path(of: parent), name)
        do {
            let stat: FileStat
            if isFolder {
                stat = try await mapped { try await self.remote.fsMkdir(path: path, parents: false) }
            } else {
                let source = try contents ?? emptyFile()
                let target = WriteTarget(path: path, ifMatch: nil, createNew: true, mkdirs: false, mode: nil)
                stat = try await mapped { try await self.remote.uploadFile(localPath: source.path, target: target, progress: nil) }
            }
            return try await item(stat, at: path)
        } catch let error as NSFileProviderError where error.code == .filenameCollision && mayAlreadyExist {
            let stat = try await mapped { try await self.remote.fsStat(path: path) }
            return try await item(stat, at: path)
        }
    }

    /// Renames, moves and new contents, in that order. New contents replace the host's file
    /// only if it is still the version they were based on; if it changed meanwhile both are
    /// kept: the host's under the name, these beside it as "name 2".
    public func modify(
        _ identifier: NSFileProviderItemIdentifier, changes: Changes, name: String, parent: NSFileProviderItemIdentifier,
        baseVersion: Data?, contents: URL?
    ) async throws -> RemoteItem {
        var path = try await self.path(of: identifier)
        if !changes.isDisjoint(with: [.filename, .parent]) {
            let directory = changes.contains(.parent) ? try await self.path(of: parent) : RemotePath.parent(path)
            let target = RemotePath.join(directory, name)
            if target != path {
                let from = path
                _ = try await mapped { try await self.remote.fsRename(from: from, to: target, overwrite: false) }
                identifiers.moved(from: from, to: target)
                path = target
            }
        }
        if changes.contains(.contents), let contents {
            let ifMatch = baseVersion.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
            let target = WriteTarget(path: path, ifMatch: ifMatch, createNew: false, mkdirs: false, mode: nil)
            do {
                let stat = try await mapped { try await self.remote.uploadFile(localPath: contents.path, target: target, progress: nil) }
                return try await item(stat, at: path)
            } catch let error as NSFileProviderError where error.code == .filenameCollision {
                try await keepBoth(contents, beside: path)
            }
        }
        let final = path
        let stat = try await mapped { try await self.remote.fsStat(path: final) }
        return try await item(stat, at: final)
    }

    /// Into the host's trash (Files' own delete is final, the host's trash is not).
    public func delete(_ identifier: NSFileProviderItemIdentifier) async throws {
        let path = try await self.path(of: identifier)
        guard path != (try await homePath()) else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        do {
            try await mapped { try await self.remote.fsDelete(path: path, mode: .trash, recursive: true) }
        } catch let error as NSFileProviderError where error.code == .noSuchItem {
            // Already gone.
        }
        identifiers.removed(path)
    }

    private func keepBoth(_ contents: URL, beside path: String) async throws {
        let name = (path as NSString).lastPathComponent
        for number in 2...50 {
            let copy = RemotePath.join(RemotePath.parent(path), Self.numbered(name, number))
            let target = WriteTarget(path: copy, ifMatch: nil, createNew: true, mkdirs: false, mode: nil)
            do {
                _ = try await mapped { try await self.remote.uploadFile(localPath: contents.path, target: target, progress: nil) }
                let home = try await homePath()
                onContainerChanged(identifier(for: RemotePath.parent(path), home: home))
                return
            } catch let error as NSFileProviderError where error.code == .filenameCollision {
                continue
            }
        }
        throw NSFileProviderError(.filenameCollision)
    }

    /// "name 2.ext".
    static func numbered(_ name: String, _ number: Int) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
    }

    private func emptyFile() throws -> URL {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let url = downloads.appending(path: "empty-\(UUID().uuidString)")
        try Data().write(to: url)
        return url
    }

    /// Runs a daemon call with its errors as File Provider errors.
    private func mapped<T>(_ call: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as WorkspaceError {
            throw Self.fileProviderError(error)
        }
    }

    static func fileProviderError(_ error: WorkspaceError) -> Error {
        switch error {
        case .NotFound: NSFileProviderError(.noSuchItem)
        case .Conflict: NSFileProviderError(.filenameCollision)
        case .Denied(let message): NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                                           userInfo: [NSLocalizedFailureReasonErrorKey: message])
        case .Disconnected: NSFileProviderError(.serverUnreachable)
        case .Invalid(let message), .Unavailable(let message), .Failed(let message):
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedFailureReasonErrorKey: message])
        }
    }
}
