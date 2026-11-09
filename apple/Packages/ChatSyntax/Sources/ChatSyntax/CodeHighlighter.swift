import Foundation
import SwiftTreeSitter

/// Synchronous, non-Sendable state owned by a rendering worker (RowBuilder's actor in the app).
/// Only immutable UTF-16 ranges cross to the UI. Neither trees nor parsers leave this object.
public final class CodeHighlighter {
    public static let maximumBytes = 16 * 1_024
    public static let maximumTokens = 1_024
    public static let cacheByteLimit = 512 * 1_024
    public static let cacheEntryLimit = 128

    private struct Key: Hashable {
        let text: String
        let language: CodeLanguage
    }
    private struct Entry {
        let tokens: [CodeToken]
        let bytes: Int
        var access: UInt64
    }
    private struct State {
        let parser: Parser
        let query: Query
    }
    private var states: [CodeLanguage: State] = [:]
    private var cache: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public private(set) var parseCount = 0
    public private(set) var cacheBytes = 0
    public private(set) var unavailableLanguages: Set<CodeLanguage> = []
    public var cacheEntryCount: Int { cache.count }

    public init() {}

    public func highlights(_ text: String, language: CodeLanguage?) -> [CodeToken] {
        guard let language, !text.isEmpty, text.utf8.count <= Self.maximumBytes,
              text.utf8.lazy.filter({ $0 == 10 }).prefix(2_000).count < 2_000 else { return [] }
        if clock == .max { cache.removeAll(); cacheBytes = 0; clock = 0 }
        clock += 1
        let key = Key(text: text, language: language)
        if var entry = cache[key] {
            entry.access = clock
            cache[key] = entry
            return entry.tokens
        }
        let tokens = parse(text, language: language)
        let bytes = text.utf8.count * 2 + tokens.count * 32 + 256
        while cache.count >= Self.cacheEntryLimit || cacheBytes + bytes > Self.cacheByteLimit {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key,
                  let entry = cache.removeValue(forKey: oldest) else { break }
            cacheBytes -= entry.bytes
        }
        cache[key] = Entry(tokens: tokens, bytes: bytes, access: clock)
        cacheBytes += bytes
        return tokens
    }

    private func parse(_ text: String, language: CodeLanguage) -> [CodeToken] {
        guard !unavailableLanguages.contains(language) else { return [] }
        let state: State
        do {
            if let existing = states[language] { state = existing }
            else {
                let parser = Parser()
                try parser.setLanguage(language.parserLanguage)
                parser.timeout = 0.01
                state = State(parser: parser, query: try language.highlightQuery())
                states[language] = state
            }
        } catch {
            unavailableLanguages.insert(language)
            return []
        }
        parseCount += 1
        guard let tree = state.parser.parse(text) else {
            state.parser.reset()
            return []
        }
        defer { state.parser.reset() }
        let cursor = state.query.execute(in: tree)
        cursor.matchLimit = 256
        let started = ContinuousClock.now
        var matches: [QueryMatch] = []
        for match in cursor.resolve(with: .init(string: text)) {
            guard matches.count < Self.maximumTokens, started.duration(to: .now) < .milliseconds(20) else { return [] }
            matches.append(match)
        }
        var tokens: [CodeToken] = []
        for highlight in matches.highlights() {
            guard let role = CodeToken.Role(capture: highlight.nameComponents),
                  highlight.range.length > 0, Range(highlight.range, in: text) != nil else { continue }
            guard tokens.count < Self.maximumTokens else { return [] }
            tokens.append(CodeToken(range: highlight.range, role: role))
        }
        return tokens
    }
}
