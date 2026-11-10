import Foundation

nonisolated struct FileListingRow: Identifiable, Sendable {
    let entry: FileEntry
    let depth: Int
    var id: String { entry.path }
}

/// A Files listing as rows. Sorting a folder of thousands with Finder's name order costs tens
/// of milliseconds, so a listing is sorted once when it arrives, off the main thread, and
/// rows are built from sorted listings.
nonisolated enum FileListingRows {
    /// Folders first, then names in Finder's order.
    static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func sortedInBackground(_ entries: [FileEntry]) async -> [FileEntry] {
        await Task.detached(priority: .userInitiated) { sorted(entries) }.value
    }

    /// The folder's entries, each expanded folder's beneath it (Finder's list view); a filter
    /// matches the folder's own entries.
    static func rows(
        _ entries: [FileEntry], filter: String, expanded: Set<String>, listings: [String: [FileEntry]]
    ) -> [FileListingRow] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty else {
            return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }.map { FileListingRow(entry: $0, depth: 0) }
        }
        var rows: [FileListingRow] = []
        rows.reserveCapacity(entries.count)
        func append(_ entries: [FileEntry], depth: Int) {
            for entry in entries {
                rows.append(FileListingRow(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) {
                    append(listings[entry.path] ?? [], depth: depth + 1)
                }
            }
        }
        append(entries, depth: 0)
        return rows
    }
}
