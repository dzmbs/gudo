import Foundation
import SwiftTreeSitter

/// At most one immutable query per bundled language. Compiling Swift's query is relatively
/// expensive in Debug, so rendering workers share it; mutable parsers remain worker-owned.
final class SharedQueries: @unchecked Sendable {
    static let instance = SharedQueries()
    private let lock = NSLock()
    private var queries: [CodeLanguage: Query] = [:]

    func query(for language: CodeLanguage) throws -> Query {
        try lock.withLock {
            if let query = queries[language] { return query }
            let query = try language.compileHighlightQuery()
            queries[language] = query
            return query
        }
    }
}
