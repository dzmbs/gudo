import Foundation
import SwiftTreeSitter

/// Synchronous, non-Sendable state owned by one rendering worker.
/// Only immutable UTF-16 ranges cross to the UI. Neither trees nor parsers leave this object.
public final class CodeHighlighter {
    public static let maximumBytes = 16 * 1_024
    public static let maximumTokens = 1_024
    public static let cacheByteLimit = 512 * 1_024
    public static let cacheEntryLimit = 128
    /// Blocks still changing (`caches: false`) keep their last highlights apart from the cache,
    /// so a later pass over the same text reuses them instead of spending its allowance again.
    static let transientEntryLimit = 16
    /// Passes a block that runs out of parse or query time gets before it stays plain.
    public static let timeoutAttempts = 3

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
    public enum Highlighting: Equatable, Sendable {
        case tokens([CodeToken])
        /// The allowance ran out before this block; it highlights on a later render.
        case deferred
    }

    private var states: [CodeLanguage: State] = [:]
    private var cache: [Key: Entry] = [:]
    private var transient: [Key: Entry] = [:]
    private var timeouts: [Key: Int] = [:]
    private let queryTimeLimit: Duration
    private var clock: UInt64 = 0
    private var allowanceDeadline: ContinuousClock.Instant?
    private var hasParsedInAllowance = false
    public private(set) var parseCount = 0
    public private(set) var cacheBytes = 0
    public private(set) var unavailableLanguages: Set<CodeLanguage> = []
    public var cacheEntryCount: Int { cache.count }

    public init(queryTimeLimit: Duration = .milliseconds(20)) {
        self.queryTimeLimit = queryTimeLimit
    }

    /// Bounds the parsing time of the highlights that follow, until `endAllowance()`. The first
    /// uncached block still parses so every allowance makes progress.
    public func beginAllowance(_ allowance: Duration) {
        allowanceDeadline = .now + allowance
        hasParsedInAllowance = false
    }

    public func endAllowance() {
        allowanceDeadline = nil
        hasParsedInAllowance = false
    }

    public func highlights(_ text: String, language: CodeLanguage?) -> [CodeToken] {
        guard case .tokens(let tokens) = highlighting(text, language: language) else { return [] }
        return tokens
    }

    public func highlighting(_ text: String, language: CodeLanguage?, caches: Bool = true) -> Highlighting {
        guard let language, !text.isEmpty, text.utf8.count <= Self.maximumBytes,
              text.utf8.lazy.filter({ $0 == 10 }).prefix(2_000).count < 2_000 else { return .tokens([]) }
        if clock == .max { cache.removeAll(); transient.removeAll(); cacheBytes = 0; clock = 0 }
        clock += 1
        let key = Key(text: text, language: language)
        if var entry = cache[key] {
            entry.access = clock
            cache[key] = entry
            return .tokens(entry.tokens)
        }
        if var entry = transient[key] {
            entry.access = clock
            transient[key] = entry
            return .tokens(entry.tokens)
        }
        if let allowanceDeadline, hasParsedInAllowance, ContinuousClock.now >= allowanceDeadline { return .deferred }
        hasParsedInAllowance = true
        guard let tokens = parse(text, language: language) ?? finalTokens(afterTimeoutOf: key) else { return .deferred }
        timeouts.removeValue(forKey: key)
        guard caches else {
            if transient.count >= Self.transientEntryLimit,
               let oldest = transient.min(by: { $0.value.access < $1.value.access })?.key {
                transient.removeValue(forKey: oldest)
            }
            transient[key] = Entry(tokens: tokens, bytes: 0, access: clock)
            return .tokens(tokens)
        }
        let bytes = text.utf8.count * 2 + tokens.count * 32 + 256
        while cache.count >= Self.cacheEntryLimit || cacheBytes + bytes > Self.cacheByteLimit {
            guard let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key,
                  let entry = cache.removeValue(forKey: oldest) else { break }
            cacheBytes -= entry.bytes
        }
        cache[key] = Entry(tokens: tokens, bytes: bytes, access: clock)
        cacheBytes += bytes
        return .tokens(tokens)
    }

    /// Plain once a block has timed out on every attempt; until then `nil`, to retry later.
    private func finalTokens(afterTimeoutOf key: Key) -> [CodeToken]? {
        let attempts = (timeouts[key] ?? 0) + 1
        guard attempts < Self.timeoutAttempts else { return [] }
        if timeouts.count >= Self.cacheEntryLimit { timeouts.removeAll() }
        timeouts[key] = attempts
        return nil
    }

    /// The block's tokens, or `nil` when the parser or the query ran out of time.
    private func parse(_ text: String, language: CodeLanguage) -> [CodeToken]? {
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
            return nil
        }
        defer { state.parser.reset() }
        let cursor = state.query.execute(in: tree)
        cursor.matchLimit = 256
        let started = ContinuousClock.now
        var matches: [QueryMatch] = []
        for match in cursor.resolve(with: .init(string: text)) {
            guard started.duration(to: .now) < queryTimeLimit else { return nil }
            guard matches.count < Self.maximumTokens else { return [] }
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
