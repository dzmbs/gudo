import Foundation
import GudoCore
import HostKit
@testable import App

nonisolated final class TimelineFixtureClient: FakeWorkspaceClient, DaemonTimelineAPI, @unchecked Sendable {
    private let snapshot: String
    private let interruptNeedsConfirmation: Bool
    private let nativeMessageReceipts: Bool
    private let photoUploads: Bool
    init(snapshot: String, interruptNeedsConfirmation: Bool = false, nativeMessageReceipts: Bool = false,
         photoUploads: Bool = false) {
        self.snapshot = snapshot
        self.interruptNeedsConfirmation = interruptNeedsConfirmation
        self.nativeMessageReceipts = nativeMessageReceipts
        self.photoUploads = photoUploads
        super.init()
    }
    func chatPrepare(paneId: UInt64) async throws -> String {
        guard nativeMessageReceipts else { throw CancellationError() }
        return try TimelineFixtureJSON.json(["Prepared": ["ticket": 1, "revision": 0, "needs_confirmation": false]])
    }
    func chatSend(paneId: UInt64, ticket: UInt64, text: String, confirmedRevision: UInt64?) async throws -> String {
        guard nativeMessageReceipts else { throw CancellationError() }
        record("send \(paneId) \(text)")
        return #""Confirmed""#
    }
    func chatInterruptPrepare(paneId: UInt64) async throws -> String {
        record("interrupt prepare \(paneId)")
        return try TimelineFixtureJSON.json(["Prepared": ["ticket": 7, "revision": 4,
                                                          "needs_confirmation": interruptNeedsConfirmation]])
    }
    func chatInterrupt(paneId: UInt64, ticket: UInt64, confirmedRevision: UInt64?) async throws -> String {
        record("interrupt \(paneId) \(ticket) \(confirmedRevision.map(String.init) ?? "none")")
        return #""InterruptRequested""#
    }
    override func fsStat(path: String) async throws -> FileStat {
        if photoUploads, path == "~" { return Self.stat("/fixture/home", size: 0, kind: .dir) }
        return try await super.fsStat(path: path)
    }
    override func uploadFile(localPath: String, target: WriteTarget, progress: (any TransferProgress)?) async throws -> FileStat {
        guard photoUploads else { return try await super.uploadFile(localPath: localPath, target: target, progress: progress) }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: localPath))
        state.withLock { $0.uploads.append(target) }
        return Self.stat(target.path, size: UInt64(bytes.count))
    }
    nonisolated(unsafe) var takesImages = false
    func sendsChatImages() -> Bool { takesImages }
    func chatSendImages(paneId: UInt64, ticket: UInt64, text: String, confirmedRevision: UInt64?, images: [Data]) async throws -> String {
        record("send images \(paneId) \(text) \(images.count)")
        return #""Confirmed""#
    }
    /// Paths `chatFileSearch` offers; empty is a helper without the search.
    nonisolated(unsafe) var searchablePaths: [String] = []
    func offersChatFileSearch() -> Bool { !searchablePaths.isEmpty }
    func chatFileSearch(paneId: UInt64, query: String, limit: UInt16) async throws -> FileMatches {
        record("files \(paneId) \(query)")
        let matches = searchablePaths.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .map { FileMatch(path: $0, kind: $0.hasSuffix("/") ? .dir : .file, positions: []) }
        return FileMatches(root: "/fixture/project", matches: matches, scanned: UInt32(searchablePaths.count), truncated: false)
    }
    /// A whole session served as the helper serves one: its latest page on watch, then older
    /// pages on request. Unset, every watch returns `snapshot`.
    nonisolated(unsafe) var session: [[String: Any]]?
    /// How long each watch and history read takes, as a link to another host does.
    nonisolated(unsafe) var latency: Duration = .zero
    static let latestPageItems = 60

    func timelineWatch(paneId: UInt64) async throws -> String {
        record("watch \(paneId)")
        if latency > .zero { try await Task.sleep(for: latency) }
        guard let session else { return snapshot }
        let start = max(0, session.count - Self.latestPageItems)
        return try ChatScenes.snapshot(Array(session[start...]), before: start > 0 ? UInt64(start) : nil)
    }
    func timelineUnwatch(paneId: UInt64) async throws { record("unwatch \(paneId)") }
    /// The page `timelineItemsBefore` returns; an empty one when nil.
    nonisolated(unsafe) var olderPage: String?
    /// Holds `timelineItemsBefore` until cleared, as a slow link does.
    nonisolated(unsafe) var holdsOlderPage = false
    nonisolated(unsafe) var olderPageRequests = 0
    func timelineItemsBefore(paneId: UInt64, before: UInt64, limit: UInt16) async throws -> String {
        olderPageRequests += 1
        while holdsOlderPage { try await Task.sleep(for: .milliseconds(5)) }
        if latency > .zero { try await Task.sleep(for: latency) }
        if let session {
            let end = min(Int(before), session.count)
            let start = max(0, end - Int(limit))
            return try ChatScenes.snapshot(Array(session[start..<end]), before: start > 0 ? UInt64(start) : nil)
        }
        return try olderPage ?? TimelineFixtureJSON.snapshot(0..<0, before: nil)
    }
    func timelineToolOutput(paneId: UInt64, handle: String, offset: UInt64, len: UInt32) async throws -> String {
        try TimelineFixtureJSON.json(["text": "Fixture output", "next_offset": NSNull(), "total_bytes": 14])
    }
}
