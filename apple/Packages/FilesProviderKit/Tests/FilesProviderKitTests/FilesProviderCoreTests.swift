import FileProvider
import Foundation
@testable import FilesProviderKit
import Synchronization
import Testing
import UniformTypeIdentifiers
import UnnamedCore

@Suite struct FilesProviderCoreTests {
    let fs = LocalFileSystem()
    let mapFile = temporaryDirectory().appending(path: "identifiers.json")
    let changed = Changed()

    final class Changed: Sendable {
        let list = Mutex<[NSFileProviderItemIdentifier]>([])
    }

    func makeCore() -> FilesProviderCore {
        let changed = changed
        return FilesProviderCore(
            remote: fs, identifiers: ItemIdentifiers(file: mapFile), downloads: temporaryDirectory(),
            onContainerChanged: { id in changed.list.withLock { $0.append(id) } })
    }

    func write(_ text: String, _ relative: String) throws {
        let url = fs.home.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func local(_ text: String) throws -> URL {
        let url = temporaryDirectory().appending(path: "contents")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func theRootIsTheHomeAndListsWhatFilesCanShow() async throws {
        try write("hello", "notes.txt")
        try write("x", "src/main.rs")
        try write("secret", ".env")
        try FileManager.default.createSymbolicLink(atPath: fs.home.appending(path: "code").path, withDestinationPath: fs.home.appending(path: "src").path)
        try FileManager.default.createSymbolicLink(atPath: fs.home.appending(path: "dangling").path, withDestinationPath: "/nowhere")
        let core = makeCore()

        let root = try await core.item(for: .rootContainer)
        #expect(root.itemIdentifier == .rootContainer)
        #expect(root.path == fs.home.path)
        #expect(root.contentType == .folder)

        let items = try await core.children(of: .rootContainer)
        #expect(items.map(\.filename).sorted() == [".env", "code", "notes.txt", "src"], "a dangling link is left out")
        #expect(items.allSatisfy { $0.parentItemIdentifier == .rootContainer })
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.filename, $0) })
        #expect(byName["notes.txt"]?.contentType == .plainText)
        #expect(byName["notes.txt"]?.documentSize == 5)
        #expect(byName["notes.txt"]?.capabilities.contains(.allowsWriting) == true)
        #expect(byName["src"]?.contentType == .folder)
        #expect(byName["src"]?.capabilities.contains(.allowsContentEnumerating) == true)
        #expect(byName["code"]?.contentType == .folder, "a link to a folder opens as one")
        #expect(byName[".env"]?.fileSystemFlags.contains(.hidden) == true)

        let src = try #require(byName["src"])
        let inside = try await core.children(of: src.itemIdentifier)
        #expect(inside.map(\.filename) == ["main.rs"])
        #expect(inside.first?.parentItemIdentifier == src.itemIdentifier)
        // The same path is the same item, from any listing, and after the extension restarts.
        #expect(try await core.item(for: inside[0].itemIdentifier).path == fs.home.appending(path: "src/main.rs").path)
        let restarted = makeCore()
        #expect(try await restarted.item(for: src.itemIdentifier).filename == "src")
        await #expect(throws: NSFileProviderError.self) { try await core.item(for: NSFileProviderItemIdentifier("unknown")) }
    }

    @Test func renamesAndMovesKeepIdentifiers() async throws {
        try write("x", "a/b/c.txt")
        try FileManager.default.createDirectory(at: fs.home.appending(path: "dest"), withIntermediateDirectories: true)
        let core = makeCore()
        let top = try await core.children(of: .rootContainer)
        let a = try #require(top.first { $0.filename == "a" })
        let dest = try #require(top.first { $0.filename == "dest" })
        let b = try #require(try await core.children(of: a.itemIdentifier).first)
        let c = try #require(try await core.children(of: b.itemIdentifier).first)

        let renamed = try await core.modify(a.itemIdentifier, changes: .filename, name: "renamed", parent: .rootContainer, baseVersion: nil, contents: nil)
        #expect(renamed.itemIdentifier == a.itemIdentifier)
        #expect(renamed.filename == "renamed")
        #expect(try await core.item(for: c.itemIdentifier).path == fs.home.appending(path: "renamed/b/c.txt").path, "what is inside follows")

        let moved = try await core.modify(c.itemIdentifier, changes: [.parent], name: "c.txt", parent: dest.itemIdentifier, baseVersion: nil, contents: nil)
        #expect(moved.itemIdentifier == c.itemIdentifier)
        #expect(moved.parentItemIdentifier == dest.itemIdentifier)
        #expect(FileManager.default.fileExists(atPath: fs.home.appending(path: "dest/c.txt").path))

        try write("y", "dest/taken.txt")
        await #expect(throws: NSFileProviderError(.filenameCollision)) {
            try await core.modify(c.itemIdentifier, changes: .filename, name: "taken.txt", parent: dest.itemIdentifier, baseVersion: nil, contents: nil)
        }
        #expect(try String(contentsOf: fs.home.appending(path: "dest/taken.txt"), encoding: .utf8) == "y", "never replaced")
    }

    @Test func createsFoldersAndFilesWithoutReplacing() async throws {
        let core = makeCore()
        let folder = try await core.create(name: "Project", in: .rootContainer, isFolder: true, contents: nil)
        #expect(folder.contentType == .folder)
        let file = try await core.create(name: "readme.md", in: folder.itemIdentifier, isFolder: false, contents: try local("# hi"))
        #expect(file.parentItemIdentifier == folder.itemIdentifier)
        #expect(try String(contentsOf: fs.home.appending(path: "Project/readme.md"), encoding: .utf8) == "# hi")
        let empty = try await core.create(name: "empty", in: folder.itemIdentifier, isFolder: false, contents: nil)
        #expect(empty.documentSize == 0)

        await #expect(throws: NSFileProviderError(.filenameCollision)) {
            try await core.create(name: "readme.md", in: folder.itemIdentifier, isFolder: false, contents: try local("other"))
        }
        // Re-created after a reinstall: the item that is there is the answer.
        let again = try await core.create(name: "readme.md", in: folder.itemIdentifier, isFolder: false, contents: try local("other"), mayAlreadyExist: true)
        #expect(again.itemIdentifier == file.itemIdentifier)
        #expect(try String(contentsOf: fs.home.appending(path: "Project/readme.md"), encoding: .utf8) == "# hi")
    }

    @Test func newContentsReplaceOnlyTheVersionTheyCameFrom() async throws {
        try write("one", "doc.txt")
        let core = makeCore()
        let doc = try #require(try await core.children(of: .rootContainer).first)
        let base = doc.itemVersion.contentVersion

        let saved = try await core.modify(doc.itemIdentifier, changes: .contents, name: "doc.txt", parent: .rootContainer, baseVersion: base, contents: try local("two"))
        #expect(saved.itemIdentifier == doc.itemIdentifier)
        #expect(saved.itemVersion.contentVersion != base)
        #expect(try String(contentsOf: fs.home.appending(path: "doc.txt"), encoding: .utf8) == "two")

        // Changed on the host since: both kept, the host's under the name.
        try write("host edit", "doc.txt")
        let after = try await core.modify(doc.itemIdentifier, changes: .contents, name: "doc.txt", parent: .rootContainer, baseVersion: saved.itemVersion.contentVersion, contents: try local("my edit"))
        #expect(after.itemIdentifier == doc.itemIdentifier)
        #expect(try String(contentsOf: fs.home.appending(path: "doc.txt"), encoding: .utf8) == "host edit")
        #expect(try String(contentsOf: fs.home.appending(path: "doc 2.txt"), encoding: .utf8) == "my edit")
        #expect(changed.list.withLock { $0 } == [.rootContainer], "the folder is listed again to show the copy")
    }

    @Test func fetchesContents() async throws {
        try write("payload", "data/blob.bin")
        let core = makeCore()
        let data = try #require(try await core.children(of: .rootContainer).first)
        let blob = try #require(try await core.children(of: data.itemIdentifier).first)
        let (url, item) = try await core.fetchContents(of: blob.itemIdentifier)
        #expect(try String(contentsOf: url, encoding: .utf8) == "payload")
        #expect(url.lastPathComponent == "blob.bin")
        #expect(item.itemIdentifier == blob.itemIdentifier)
    }

    @Test func deletesIntoTheHostsTrash() async throws {
        try write("x", "old/file.txt")
        let core = makeCore()
        let old = try #require(try await core.children(of: .rootContainer).first)
        let file = try #require(try await core.children(of: old.itemIdentifier).first)
        try await core.delete(old.itemIdentifier)
        #expect(!FileManager.default.fileExists(atPath: fs.home.appending(path: "old").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fs.trash.path).count == 1, "recoverable on the host")
        await #expect(throws: NSFileProviderError(.noSuchItem)) { try await core.item(for: file.itemIdentifier) }
        await #expect(throws: (any Error).self) { try await core.delete(.rootContainer) }
        #expect(FileManager.default.fileExists(atPath: fs.home.path))
    }

    @Test func theWorkingSetFollowsFoldersListedLately() async throws {
        try write("1", "a/one.txt")
        try write("2", "b/two.txt")
        let core = makeCore()
        let top = try await core.children(of: .rootContainer)
        let a = try #require(top.first { $0.filename == "a" })
        _ = try await core.children(of: a.itemIdentifier)
        #expect(Set(try await core.children(of: .workingSet).map(\.filename)) == ["a", "b", "one.txt"])

        // Changed on the host: the set says so; a folder that went away leaves it.
        try write("3", "a/three.txt")
        #expect(Set(try await core.workingSet().map(\.filename)) == ["a", "b", "one.txt", "three.txt"])
        try FileManager.default.removeItem(at: fs.home.appending(path: "a"))
        #expect(Set(try await core.workingSet().map(\.filename)) == ["b"])
        #expect(core.identifiers.visitedDirectories == [fs.home.path])
    }

    @Test func daemonErrorsBecomeFileProviderErrors() {
        func code(_ error: WorkspaceError) -> Int? { (FilesProviderCore.fileProviderError(error) as NSError).code }
        #expect(code(.NotFound(message: "")) == NSFileProviderError.Code.noSuchItem.rawValue)
        #expect(code(.Conflict(message: "")) == NSFileProviderError.Code.filenameCollision.rawValue)
        #expect(code(.Disconnected) == NSFileProviderError.Code.serverUnreachable.rawValue)
        #expect(code(.Denied(message: "")) == NSFileWriteNoPermissionError)
    }

    @Test func identifierMapsAreBoundedAndPersist() {
        let ids = ItemIdentifiers(file: mapFile)
        for index in 0..<(ItemIdentifiers.visitedLimit + 10) { ids.visited("/d\(index)") }
        #expect(ids.visitedDirectories.count == ItemIdentifiers.visitedLimit)
        #expect(ids.visitedDirectories.first == "/d\(ItemIdentifiers.visitedLimit + 9)")
        let id = ids.identifier(for: "/d1/x")
        #expect(ItemIdentifiers(file: mapFile).path(for: id) == "/d1/x")
        #expect(RemotePath.parent("/a") == "/")
        #expect(RemotePath.isWithin("/a/b", "/a") && !RemotePath.isWithin("/ab", "/a"))
    }
}
