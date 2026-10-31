import Foundation
import os
import PaneLayout
import TerminalCore

/// A host's workspace as this device last saw it: the layout, names, projects and each pane's
/// screen. The app draws it at launch before the host answers (instant start,
/// docs/APP-ARCHITECTURE.md §26); the host's own state replaces it when it arrives.
nonisolated public struct CachedWorkspace: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = Self.currentVersion
    public var hostId: String
    /// The daemon it came from: a host paired again with another daemon starts clean.
    public var daemonId: String?
    public var sessionId: UInt64?
    public var sessionName: String
    public var session: Session
    public var projects: HostProjects
    public var panes: [UInt64: CachedPane]
    public var savedAt: Date

    public init(
        hostId: String, daemonId: String?, sessionId: UInt64?, sessionName: String = "", session: Session,
        projects: HostProjects = HostProjects(), panes: [UInt64: CachedPane] = [:], savedAt: Date = .now
    ) {
        self.hostId = hostId
        self.daemonId = daemonId
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.session = session
        self.projects = projects
        self.panes = panes
        self.savedAt = savedAt
    }

    /// The same workspace with each pane's screen taken from its terminal (any thread).
    public func capturingScreens(_ terminals: [UInt64: Terminal], limits: WorkspaceCacheLimits = .init()) -> CachedWorkspace {
        var result = self
        for (id, terminal) in terminals {
            guard let pane = panes[id] else { continue }
            result.panes[id] = CachedPane(terminal: terminal, title: pane.title, cwd: pane.cwd, limits: limits)
        }
        return result
    }

    /// Panes in the order their screens are worth keeping: the active tab's (focused first),
    /// then every other tab's in tab order.
    public var screenPriority: [UInt64] {
        var order: [PaneId] = []
        if let active = session.activeTab {
            order.append(active.focused)
            order += active.root.panes.filter { $0 != active.focused }
        }
        for tab in session.tabs where tab.id != session.activeTabId { order += tab.root.panes }
        return order.map(\.rawValue)
    }

    /// Within `limits`: screens of panes the layout no longer has go, then screens past the
    /// host's budget, least important first. Names and the layout always stay.
    public func bounded(by limits: WorkspaceCacheLimits) -> CachedWorkspace {
        var result = self
        let live = Set(session.panes.map(\.rawValue))
        result.panes = panes.filter { live.contains($0.key) }
        var used = 0
        for id in screenPriority {
            guard var pane = result.panes[id] else { continue }
            let size = pane.byteCount
            if pane.screen == nil || size > limits.screenBytes || used + size > limits.hostBytes {
                pane.dropScreen()
            } else {
                used += size
            }
            result.panes[id] = pane
        }
        return result
    }
}

/// One pane of a cached workspace.
nonisolated public struct CachedPane: Codable, Sendable, Equatable {
    public var title: String
    public var cwd: String?
    public var cols: UInt16
    public var rows: UInt16
    /// The screen: a Ghostty snapshot's READY section. Nil: not kept (the pane shows its
    /// background until the host sends it).
    public var screen: Data?
    /// The most recent scrollback above the screen, as whole history records.
    public var history: Data
    /// How many rows the viewport was scrolled back from the bottom.
    public var scrolledBack: Int

    public init(
        title: String = "", cwd: String? = nil, cols: UInt16 = 0, rows: UInt16 = 0, screen: Data? = nil,
        history: Data = Data(), scrolledBack: Int = 0
    ) {
        self.title = title
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.screen = screen
        self.history = history
        self.scrolledBack = scrolledBack
    }

    /// The pane's screen and a little scrollback, taken from its terminal.
    public init(terminal: Terminal, title: String, cwd: String?, limits: WorkspaceCacheLimits = .init()) {
        let size = terminal.size
        self.init(title: title, cwd: cwd, cols: UInt16(clamping: size.cols), rows: UInt16(clamping: size.rows))
        guard let snapshot = terminal.encodeSnapshot(),
              let (ready, rest) = Terminal.splitSnapshot(snapshot, images: false),
              ready.count <= limits.screenBytes
        else { return }
        screen = Data(ready)
        history = Self.recentHistory(Data(rest), limit: limits.historyBytes)
        let bar = terminal.scrollbar
        scrolledBack = max(0, bar.total - bar.offset - bar.visible)
    }

    var byteCount: Int { (screen?.count ?? 0) + history.count }

    mutating func dropScreen() {
        screen = nil
        history = Data()
        scrolledBack = 0
    }

    /// The newest history records that fit in `limit`, cut at a record boundary (history comes
    /// newest first, and a partial record would be waited for forever).
    static func recentHistory(_ records: Data, limit: Int) -> Data {
        let bytes = [UInt8](records)
        var offset = 0
        while offset + 10 <= bytes.count {
            let length = (0..<4).reduce(0) { $0 | Int(bytes[offset + 2 + $1]) << (8 * $1) }
            let end = offset + 10 + length
            guard end <= bytes.count, end <= limit else { break }
            offset = end
        }
        return Data(bytes.prefix(offset))
    }
}

/// How much a cached workspace may hold. Terminal contents are sensitive and the cache is
/// read at every launch: only what the first frame needs.
nonisolated public struct WorkspaceCacheLimits: Sendable, Equatable {
    /// A pane's screen (READY) at most; larger ones (big images) are not kept.
    public var screenBytes = 256 * 1024
    /// Scrollback kept above a pane's screen.
    public var historyBytes = 32 * 1024
    /// Every pane's screen and scrollback together, per host.
    public var hostBytes = 2 * 1024 * 1024
    /// A workspace older than this is not shown.
    public var maxAge: TimeInterval = 14 * 24 * 3600

    public init() {}
}

/// Cached workspaces on disk, one file per host: owner-only, out of backups, and on iOS
/// readable only after the first unlock. Safe to use from any thread.
nonisolated public final class WorkspaceCacheStore: Sendable {
    public let directory: URL
    public let limits: WorkspaceCacheLimits
    private static let magic = Data("UNWS".utf8)
    private static let log = Logger(subsystem: Log.subsystem, category: "cache")

    public init(directory: URL, limits: WorkspaceCacheLimits = .init()) {
        self.directory = directory
        self.limits = limits
    }

    /// The app's store: in Caches (never backed up; the system may purge it, which only costs
    /// one instant start), or in `isolated` for tests and tooling.
    public static func appDefault(isolated: URL? = nil) -> WorkspaceCacheStore {
        let base = isolated ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "app", directoryHint: .isDirectory)
        return WorkspaceCacheStore(directory: base.appending(path: "Workspaces", directoryHint: .isDirectory))
    }

    /// The host's cached workspace, if it is still the host's: same daemon, same session,
    /// this format, not too old. Anything else is deleted.
    public func load(hostId: String, daemonId: String?, sessionId: UInt64?, now: Date = .now) -> CachedWorkspace? {
        let url = file(for: hostId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let cached = Self.decode(data), cached.hostId == hostId, cached.daemonId == daemonId,
              sessionId == nil || cached.sessionId == sessionId,
              now.timeIntervalSince(cached.savedAt) < limits.maxAge
        else {
            Self.log.info("dropping a stale workspace cache for host=\(hostId, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return cached
    }

    /// Writes the workspace within the limits, replacing the host's previous one.
    public func save(_ workspace: CachedWorkspace) throws {
        try prepareDirectory()
        let data = try Self.encode(workspace.bounded(by: limits))
        let url = file(for: workspace.hostId)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    public func remove(hostId: String) {
        try? FileManager.default.removeItem(at: file(for: hostId))
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(for hostId: String) -> URL {
        let name = hostId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "host"
        return directory.appending(path: name + ".workspace")
    }

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    static func encode(_ workspace: CachedWorkspace) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try encoder.encode(workspace)
        let compressed = try (plist as NSData).compressed(using: .lzfse) as Data
        return magic + compressed
    }

    static func decode(_ data: Data) -> CachedWorkspace? {
        guard data.starts(with: magic),
              let plist = try? (data.dropFirst(magic.count) as NSData).decompressed(using: .lzfse) as Data,
              let cached = try? PropertyListDecoder().decode(CachedWorkspace.self, from: plist),
              cached.version == CachedWorkspace.currentVersion
        else { return nil }
        return cached
    }
}
