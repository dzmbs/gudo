import Foundation
import Observation

/// The search engine the address field searches with (Settings ▸ Browser).
nonisolated enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google, duckDuckGo, bing, kagi, brave

    var id: String { rawValue }

    static let key = "browserSearchEngine"

    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: key).flatMap(SearchEngine.init) ?? .google
    }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        }
    }

    private var base: String {
        switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .kagi: "https://kagi.com/search"
        case .brave: "https://search.brave.com/search"
        }
    }

    func url(searching query: String) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}

/// What the address field makes of what was typed: a URL (`https://…`, `about:blank`), a local
/// server (`localhost:3000`, `127.0.0.1:8080`, `:5173`, `app.localhost`), a bare host
/// (`example.com`, `example.com/docs`, `devbox:8080`), else a search.
nonisolated enum BrowserAddress {
    static func url(for input: String, engine: SearchEngine = .current) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return address(text) ?? engine.url(searching: text)
    }

    /// The URL `text` names, nil when it reads as a search.
    static func address(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        if text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
            || text.lowercased().hasPrefix("about:")
        {
            return URL(string: text)
        }
        if text.hasPrefix(":"), UInt16(text.dropFirst().prefix { $0.isNumber }) != nil {
            return URL(string: "http://localhost" + text)
        }
        let authority = String(text.prefix { !"/?#".contains($0) })
        var host = authority.lowercased()
        var hasPort = false
        if let colon = host.lastIndex(of: ":"), !host.hasPrefix("[") || host[..<colon].hasSuffix("]") {
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber), UInt16(port) != nil else { return nil }
            host = String(host[..<colon])
            hasPort = true
        }
        guard !host.isEmpty else { return nil }
        if WindowModel.isLoopback(host) || isIPv4(host) {
            return URL(string: "http://" + text)
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let validLabels = labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        guard validLabels else { return nil }
        if labels.count > 1, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) {
            return URL(string: (host.hasSuffix(".local") ? "http://" : "https://") + text)
        }
        // A machine on the network by name, with the port its server took.
        if labels.count == 1, hasPort { return URL(string: "http://" + text) }
        return nil
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}

/// Pages visited in the in-app browser, on this device: the start page's frequent and recent
/// pages and the address field's suggestions.
@MainActor
@Observable
final class BrowserHistory {
    static let shared = BrowserHistory()

    nonisolated struct Entry: Codable, Hashable, Sendable {
        var url: String
        var title: String
        var visits: Int
        var lastVisit: Date
    }

    private(set) var entries: [Entry]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "browserHistory"
    private static let limit = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// A page the browser reached. Sign-in callbacks and blank pages are not kept.
    func record(_ url: URL, title: String?) {
        guard url.scheme == "http" || url.scheme == "https", SignInLink.pastedCode(from: url) == nil,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "code" }) != true
        else { return }
        let key = url.absoluteString
        if let index = entries.firstIndex(where: { $0.url == key }) {
            entries[index].visits += 1
            entries[index].lastVisit = .now
            if let title, !title.isEmpty { entries[index].title = title }
        } else {
            entries.append(Entry(url: key, title: title ?? "", visits: 1, lastVisit: .now))
            if entries.count > Self.limit {
                entries.sort { $0.lastVisit > $1.lastVisit }
                entries.removeLast(entries.count - Self.limit)
            }
        }
        save()
    }

    /// A title that arrived after the page was recorded.
    func retitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, let index = entries.firstIndex(where: { $0.url == url.absoluteString }),
              entries[index].title != title else { return }
        entries[index].title = title
        save()
    }

    func clear() {
        entries = []
        save()
    }

    var frequent: [Entry] {
        Array(entries.sorted { ($0.visits, $0.lastVisit) > ($1.visits, $1.lastVisit) }.prefix(8))
    }

    var recent: [Entry] {
        Array(entries.sorted { $0.lastVisit > $1.lastVisit }.prefix(6))
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}

/// One row under the address field while typing.
nonisolated struct AddressSuggestion: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case devServer, page, search }
    var kind: Kind
    var title: String
    var detail: String
    var url: URL
    var id: String { "\(kind)|\(url.absoluteString)" }

    var systemImage: String {
        switch kind {
        case .devServer: "server.rack"
        case .page: "clock"
        case .search: "magnifyingglass"
        }
    }

    /// Dev servers whose `localhost:<port>` or process matches, then visited pages whose
    /// address or title does (address prefixes first, then by visits), then the search.
    static func make(
        for input: String, history: [BrowserHistory.Entry], devServers: [DetectedPort], engine: SearchEngine,
        limit: Int = 6
    ) -> [AddressSuggestion] {
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        var out: [AddressSuggestion] = devServers.filter(\.isHTTP).compactMap { port in
            let name = "localhost:\(port.port)"
            guard name.contains(query) || port.process.lowercased().contains(query) || String(port.port).hasPrefix(query)
            else { return nil }
            return AddressSuggestion(
                kind: .devServer, title: name, detail: port.pane.map { "\(port.process) · \($0)" } ?? port.process,
                url: DevServerRouting.pageURL(for: port))
        }
        let pages = history.compactMap { entry -> (Int, BrowserHistory.Entry, URL)? in
            guard let url = URL(string: entry.url) else { return nil }
            let bare = Self.bare(entry.url)
            if bare.hasPrefix(query) { return (0, entry, url) }
            if bare.contains(query) || entry.title.lowercased().contains(query) { return (1, entry, url) }
            return nil
        }
        .sorted { ($0.0, -$0.1.visits) < ($1.0, -$1.1.visits) }
        out += pages.map { _, entry, url in
            AddressSuggestion(kind: .page, title: entry.title.isEmpty ? Self.bare(entry.url) : entry.title, detail: Self.bare(entry.url), url: url)
        }
        out = Array(out.prefix(limit - 1))
        if BrowserAddress.address(query) == nil {
            out.append(AddressSuggestion(
                kind: .search, title: input.trimmingCharacters(in: .whitespaces), detail: "\(engine.title) Search",
                url: engine.url(searching: input.trimmingCharacters(in: .whitespaces))))
        }
        return out
    }

    /// The selection after an arrow key: -1 is none (the typed text).
    static func step(_ selection: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return -1 }
        let next = selection + step
        return next < -1 ? count - 1 : next >= count ? -1 : next
    }

    /// `https://www.example.com/a/` as `example.com/a`.
    static func bare(_ url: String) -> String {
        var text = url.lowercased()
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
