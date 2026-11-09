import Foundation
import SwiftTreeSitter

/// At most one immutable query per bundled language. Compiling Swift's query is relatively
/// expensive in Debug, so rendering workers share it; mutable parsers remain worker-owned.
final class SharedQueries: Sendable {
    static let instance = SharedQueries()
    private let slots: [CodeLanguage: QuerySlot] = Dictionary(
        uniqueKeysWithValues: CodeLanguage.allCases.map { ($0, QuerySlot()) }
    )

    func query(for language: CodeLanguage) throws -> Query {
        guard let slot = slots[language] else { return try language.compileHighlightQuery() }
        return try slot.query { try language.compileHighlightQuery() }
    }
}

private final class QuerySlot: @unchecked Sendable {
    private let lock = NSLock()
    private var compiled: Query?

    func query(_ compile: () throws -> Query) throws -> Query {
        try lock.withLock {
            if let compiled { return compiled }
            let query = try compile()
            compiled = query
            return query
        }
    }
}
