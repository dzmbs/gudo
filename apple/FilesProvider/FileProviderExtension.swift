import FileProvider
import FilesProviderKit
import Foundation
import os
import UniformTypeIdentifiers

/// A paired host in the Files app (one domain per host, its home as the root). Everything is
/// `FilesProviderKit`; this is the File Provider's calling convention around it. Builds without
/// the shared groups (`FILES_PROVIDER = NO`) never add a domain, so it never runs there.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let session: HostFilesSession?
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "files", category: "files")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let service = (Bundle.main.object(forInfoDictionaryKey: "FilesSecretsService") as? String) ?? "secrets"
        let manager = UncheckedHandler(NSFileProviderManager(for: domain))
        session = FilesShare.shared(service: service).map { share in
            HostFilesSession(share: share, hostId: domain.identifier.rawValue) {
                manager.call?.signalEnumerator(for: .workingSet) { _ in }
            }
        }
        super.init()
    }

    func invalidate() {
        session?.close()
    }

    /// Runs `work` on the host's files and answers the system's completion handler.
    private func run<T: Sendable>(
        _ what: String, _ completion: @escaping @Sendable (T?, Error?) -> Void,
        _ work: @escaping @Sendable (FilesProviderCore) async throws -> T
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task { [session] in
            do {
                guard let session else { throw NSFileProviderError(.notAuthenticated) }
                let result = try await work(try session.core())
                progress.completedUnitCount = 1
                completion(result, nil)
            } catch {
                Self.log.error("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
                completion(nil, error)
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func item(
        for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedHandler(completionHandler)
        return run("item", { (item: RemoteItem?, error) in completion.call(item, error) }) { try await $0.item(for: identifier) }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedHandler(completionHandler)
        return run("fetch", { (result: FetchResult?, error) in completion.call(result?.url, result?.item, error) }) {
            let (url, item) = try await $0.fetchContents(of: itemIdentifier)
            return FetchResult(url: url, item: item)
        }
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
        options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedHandler(completionHandler)
        let name = itemTemplate.filename
        let parent = itemTemplate.parentItemIdentifier
        let type = itemTemplate.contentType ?? .data
        guard type.conforms(to: .folder) || !type.conforms(to: .symbolicLink) else {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return Progress()
        }
        let mayAlreadyExist = options.contains(.mayAlreadyExist)
        return run("create", { (item: RemoteItem?, error) in completion.call(item, [], false, error) }) {
            try await $0.create(name: name, in: parent, isFolder: type.conforms(to: .folder), contents: url, mayAlreadyExist: mayAlreadyExist)
        }
    }

    func modifyItem(
        _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
        contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let completion = UncheckedHandler(completionHandler)
        var changes: FilesProviderCore.Changes = []
        if changedFields.contains(.contents) { changes.insert(.contents) }
        if changedFields.contains(.filename) { changes.insert(.filename) }
        if changedFields.contains(.parentItemIdentifier) { changes.insert(.parent) }
        // Dates, tags and extended attributes stay on this device.
        let identifier = item.itemIdentifier
        let name = item.filename
        let parent = item.parentItemIdentifier
        let base = version.contentVersion
        let fields = changes
        return run("modify", { (item: RemoteItem?, error) in completion.call(item, [], false, error) }) {
            try await $0.modify(identifier, changes: fields, name: name, parent: parent, baseVersion: base, contents: newContents)
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let completion = UncheckedHandler(completionHandler)
        return run("delete", { (_: Bool?, error) in completion.call(error) }) {
            try await $0.delete(identifier)
            return true
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard let session else { throw NSFileProviderError(.notAuthenticated) }
        return Enumerator(container: containerItemIdentifier, session: session)
    }
}

private struct FetchResult: @unchecked Sendable {
    let url: URL
    let item: NSFileProviderItem
}

/// The system's completion handlers are not `Sendable`; each is called exactly once.
private struct UncheckedHandler<F>: @unchecked Sendable {
    let call: F
    init(_ call: F) { self.call = call }
}

/// A folder's items, or the working set (the folders listed lately). Changes are never
/// itemised: when the session's anchor moved, the system lists again from scratch and works
/// out what changed.
final class Enumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let container: NSFileProviderItemIdentifier
    private let session: HostFilesSession

    init(container: NSFileProviderItemIdentifier, session: HostFilesSession) {
        self.container = container
        self.session = session
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observer = UncheckedHandler(observer)
        let (container, session) = (container, session)
        Task {
            do {
                let items = try await session.core().children(of: container)
                observer.call.didEnumerate(items)
                observer.call.finishEnumerating(upTo: nil)
                await session.watchVisited()
            } catch {
                observer.call.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if session.isCurrent(anchor) {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(session.anchor)
    }
}
