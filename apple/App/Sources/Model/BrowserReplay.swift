import Foundation
import Observation
import UniformTypeIdentifiers

/// An agent driving one page: its actions, the page's rrweb events and one picture per action.
nonisolated struct ReplaySession: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var started: Date
    var ended: Date
    var title: String
    var hostId: String?
    var paneId: UInt64?
    var page: UUID?
    var actions: [ReplayAction] = []
    /// Opened from a file, so playback loads nothing from the network.
    var imported = false
    /// Events stopped at the size cap; actions go on.
    var truncated = false

    var startURL: String? { actions.first?.urlBefore ?? actions.first?.urlAfter }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return actions.lazy.compactMap { $0.urlAfter.flatMap(URL.init(string:))?.host() }.first ?? "Browser Session"
    }

    init(id: UUID = UUID(), started: Date, title: String = "", hostId: String? = nil, paneId: UInt64? = nil, page: UUID? = nil) {
        self.id = id
        self.started = started
        ended = started
        self.title = title
        self.hostId = hostId
        self.paneId = paneId
        self.page = page
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        started = try container.decode(Date.self, forKey: .started)
        ended = try container.decode(Date.self, forKey: .ended)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        hostId = try container.decodeIfPresent(String.self, forKey: .hostId)
        paneId = try container.decodeIfPresent(UInt64.self, forKey: .paneId)
        page = try container.decodeIfPresent(UUID.self, forKey: .page)
        actions = try container.decodeIfPresent([ReplayAction].self, forKey: .actions) ?? []
        imported = try container.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

nonisolated struct ReplayAction: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var tool: String
    var ref: String?
    var role: String?
    var name: String?
    var nth: Int?
    /// JSON with sorted keys.
    var args: String
    var urlBefore: String?
    var urlAfter: String?
    var time: Date
    var verdict: String
    var selector: String?
    var locator: String?
    /// File name of the picture after the action.
    var keyframe: String?

    var kind: String { tool.hasPrefix("browser_") ? String(tool.dropFirst(8)) : tool }

    var arguments: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
    }

    var target: String {
        if let role, let name, !name.isEmpty { return "\(role) “\(name)”" + ((nth ?? 0) > 0 ? " #\((nth ?? 0) + 1)" : "") }
        if let locator { return locator }
        let input = arguments
        if kind == "navigate" { return urlAfter ?? input["url"] as? String ?? "" }
        if kind == "press" { return input["keys"] as? String ?? "" }
        if let ref { return ref }
        if let point = input["target"] as? [String: Any], point["type"] as? String == "coordinate" {
            return "(\((point["x"] as? NSNumber)?.intValue ?? 0), \((point["y"] as? NSNumber)?.intValue ?? 0))"
        }
        if kind == "scroll" { return input["direction"] as? String ?? "" }
        return ""
    }

    var succeeded: Bool {
        let text = verdict.lowercased()
        return !(text.hasPrefix("fail") || text.hasPrefix("nothing") || text.contains("no observable effect") || text.contains("no effect")
            || text.contains("did not") || text.contains("declined") || text.contains("error"))
    }
}

extension ReplayAction {
    init(_ entry: BrowserActionEntry, id: Int) {
        self.init(
            id: id, tool: entry.tool, ref: entry.ref, role: entry.role, name: entry.name, nth: entry.nth, args: entry.args,
            urlBefore: entry.urlBefore?.absoluteString, urlAfter: entry.urlAfter?.absoluteString, time: entry.time,
            verdict: entry.verdict, selector: entry.selector, locator: entry.locator)
    }
}

/// A folder per session (`session.json`, `events.jsonl`, `k<N>.jpg`), within a total size and an age.
@MainActor
@Observable
final class ReplayStore {
    static let shared = ReplayStore(root: AppData.replays)

    static let enabledKey = "recordAgentBrowserSessions"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    nonisolated static let fileExtension = "gudoreplay"
    /// Exported in Info.plist.
    nonisolated static let fileType = UTType(exportedAs: (Bundle.main.object(forInfoDictionaryKey: "ReplayTypeIdentifier") as? String) ?? "dev.gudo.gudoreplay", conformingTo: .data)

    let root: URL
    /// Total bytes; the oldest sessions go first.
    var capacity: Int
    var maxAge: TimeInterval
    /// One session's event bytes; its actions and pictures go on.
    var sessionEventCap: Int

    /// Newest first.
    private(set) var sessions: [ReplaySession] = []
    @ObservationIgnored private var eventBytes: [UUID: Int] = [:]
    @ObservationIgnored private var handles: [UUID: FileHandle] = [:]

    init(root: URL, capacity: Int = 512 << 20, maxAge: TimeInterval = 30 * 86_400, sessionEventCap: Int = 96 << 20) {
        self.root = root
        self.capacity = capacity
        self.maxAge = maxAge
        self.sessionEventCap = sessionEventCap
        reload()
    }

    func directory(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }

    func session(_ id: UUID) -> ReplaySession? { sessions.first { $0.id == id } }

    func sessions(hostId: String, paneId: UInt64) -> [ReplaySession] {
        sessions.filter { $0.hostId == hostId && $0.paneId == paneId }
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        sessions = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "session.json")) else { return nil }
            return try? Self.decoder.decode(ReplaySession.self, from: data)
        }
        .sorted { $0.started > $1.started }
    }

    @discardableResult
    func create(_ session: ReplaySession) throws -> ReplaySession {
        try FileManager.default.createDirectory(at: directory(session.id), withIntermediateDirectories: true)
        try save(session)
        return session
    }

    func save(_ session: ReplaySession) throws {
        try FileManager.default.createDirectory(at: directory(session.id), withIntermediateDirectories: true)
        try Self.encoder.encode(session).write(to: directory(session.id).appending(path: "session.json"), options: .atomic)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: sessions.firstIndex { $0.started < session.started } ?? sessions.endIndex)
        }
    }

    /// False once the session reached its cap.
    @discardableResult
    func append(events: [String], to id: UUID) -> Bool {
        guard !events.isEmpty else { return true }
        let url = directory(id).appending(path: "events.jsonl")
        let used = eventBytes[id] ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let data = Data((events.joined(separator: "\n") + "\n").utf8)
        guard used + data.count <= sessionEventCap else { return false }
        if handles[id] == nil {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handles[id] = try? FileHandle(forWritingTo: url)
            _ = try? handles[id]?.seekToEnd()
        }
        guard let handle = handles[id], (try? handle.write(contentsOf: data)) != nil else { return false }
        eventBytes[id] = used + data.count
        return true
    }

    func close(_ id: UUID) {
        try? handles.removeValue(forKey: id)?.close()
    }

    func writeKeyframe(_ jpeg: Data, session id: UUID, action: Int) -> String? {
        let name = "k\(action).jpg"
        do {
            try jpeg.write(to: directory(id).appending(path: name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func keyframe(_ name: String, session id: UUID) -> Data? {
        guard Self.isKeyframeName(name) else { return nil }
        return try? Data(contentsOf: directory(id).appending(path: name))
    }

    func eventLines(_ id: UUID) -> [Substring] {
        guard let data = try? Data(contentsOf: directory(id).appending(path: "events.jsonl")) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }

    func delete(_ id: UUID) {
        close(id)
        eventBytes[id] = nil
        try? FileManager.default.removeItem(at: directory(id))
        sessions.removeAll { $0.id == id }
    }

    func deleteAll() {
        for session in sessions { delete(session.id) }
    }

    func size(_ id: UUID) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(id), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    var totalSize: Int { sessions.reduce(0) { $0 + size($1.id) } }

    /// Never deletes a session being recorded.
    func cleanUp(keeping live: Set<UUID> = [], now: Date = .now) {
        for session in sessions where !live.contains(session.id) && now.timeIntervalSince(session.ended) > maxAge {
            delete(session.id)
        }
        var total = totalSize
        for session in sessions.reversed() where total > capacity && !live.contains(session.id) {
            total -= size(session.id)
            delete(session.id)
        }
    }

    // MARK: `.gudoreplay` files

    /// `{"format":"gudoreplay","version":1,"session":…,"events":[…],"keyframes":{name: base64}}`,
    /// the same bytes for the same session.
    func bundle(_ id: UUID) throws -> Data {
        guard let session = session(id) else { throw CocoaError(.fileNoSuchFile) }
        let frames = session.actions.compactMap(\.keyframe).compactMap { name in keyframe(name, session: id).map { (name, $0) } }
        return try Self.bundle(session, events: eventLines(id), keyframes: frames)
    }

    nonisolated static func bundle(_ session: ReplaySession, events: [Substring], keyframes: [(String, Data)]) throws -> Data {
        var exported = session
        exported.imported = false
        // Which host, pane and page recorded it means nothing on another device.
        (exported.hostId, exported.paneId, exported.page) = (nil, nil, nil)
        var file = Data(#"{"format":"gudoreplay","version":1,"session":"#.utf8)
        file += try encoder.encode(exported)
        file += Data(#","events":["#.utf8)
        for (index, line) in events.enumerated() {
            if index > 0 { file += Data(",".utf8) }
            file += Data(line.utf8)
        }
        file += Data(#"],"keyframes":{"#.utf8)
        for (index, (name, data)) in keyframes.sorted(by: { $0.0 < $1.0 }).enumerated() {
            if index > 0 { file += Data(",".utf8) }
            file += Data("\"\(name)\":\"\(data.base64EncodedString())\"".utf8)
        }
        file += Data("}}".utf8)
        return file
    }

    /// A session already on the device opens as is.
    @discardableResult
    func importBundle(_ data: Data) throws -> ReplaySession {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == "gudoreplay", let raw = object["session"]
        else { throw CocoaError(.fileReadCorruptFile) }
        var session = try Self.decoder.decode(ReplaySession.self, from: JSONSerialization.data(withJSONObject: raw))
        if self.session(session.id) != nil { return self.session(session.id)! }
        session.imported = true
        // A file must not pass itself off as a recording of one of this device's panes.
        (session.hostId, session.paneId, session.page) = (nil, nil, nil)
        let frames = object["keyframes"] as? [String: String] ?? [:]
        for index in session.actions.indices {
            guard let name = session.actions[index].keyframe else { continue }
            if !Self.isKeyframeName(name) || frames[name] == nil { session.actions[index].keyframe = nil }
        }
        try create(session)
        for (name, base64) in frames where Self.isKeyframeName(name) {
            try Data(base64Encoded: base64)?.write(to: directory(session.id).appending(path: name))
        }
        let events = (object["events"] as? [Any] ?? []).compactMap { event in
            (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
        }
        append(events: events, to: session.id)
        close(session.id)
        return session
    }

    nonisolated private static func isKeyframeName(_ name: String) -> Bool {
        name.wholeMatch(of: /k[0-9]{1,6}\.jpg/) != nil
    }

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // rrweb's clock: events and actions share one timeline.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
