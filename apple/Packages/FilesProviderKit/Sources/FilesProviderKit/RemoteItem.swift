import FileProvider
import Foundation
import UniformTypeIdentifiers
import UnnamedCore

/// A file or folder on the host as Files sees it.
nonisolated public final class RemoteItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let contentType: UTType
    public let documentSize: NSNumber?
    public let contentModificationDate: Date?
    public let itemVersion: NSFileProviderItemVersion
    public let capabilities: NSFileProviderItemCapabilities
    public let fileSystemFlags: NSFileProviderFileSystemFlags
    /// The host's path (not shown; for the provider and tests).
    public let path: String

    /// Nil for what Files cannot show: sockets, FIFOs, devices, dangling links.
    init?(_ stat: FileStat, path: String, identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier) {
        let kind = stat.kind == .symlink ? stat.targetKind : stat.kind
        guard let kind, kind == .file || kind == .dir else { return nil }
        let isFolder = kind == .dir
        itemIdentifier = identifier
        parentItemIdentifier = parent
        filename = stat.name
        self.path = path
        contentType = isFolder ? .folder : UTType(filenameExtension: (stat.name as NSString).pathExtension) ?? .data
        documentSize = isFolder ? nil : NSNumber(value: stat.size)
        contentModificationDate = Date(timeIntervalSince1970: Double(stat.modifiedMs) / 1000)
        // The daemon's version changes with the content (inode, size, mtime); a rename keeps
        // it, so the name is part of the metadata version.
        itemVersion = NSFileProviderItemVersion(
            contentVersion: Data(stat.version.utf8), metadataVersion: Data("\(stat.version)/\(stat.name)".utf8))
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        if isFolder {
            capabilities.formUnion([.allowsContentEnumerating, .allowsAddingSubItems])
        } else {
            capabilities.insert(.allowsWriting)
        }
        self.capabilities = capabilities
        var flags: NSFileProviderFileSystemFlags = [.userReadable]
        if stat.mode & 0o200 != 0 { flags.insert(.userWritable) }
        if stat.mode & 0o100 != 0, !isFolder { flags.insert(.userExecutable) }
        if isFolder { flags.insert(.userExecutable) }
        if stat.hidden { flags.insert(.hidden) }
        fileSystemFlags = flags
    }
}
