import Foundation
@testable import App

/// A minified bundle and a huge image, served as a host's files and changes would be.
final class OversizedFiles: FileSource {
    let root = "~/site"
    let hostName = "studio"
    let unavailableReason: String? = nil
    let text: String
    let image: Data
    let textEntry = FileEntry(path: "~/site/bundle.min.js", name: "bundle.min.js", isDirectory: false, size: 1_050_000)
    let imageEntry = FileEntry(path: "~/site/poster.png", name: "poster.png", isDirectory: false, size: 120_000)

    init(text: String, image: Data) {
        self.text = text
        self.image = image
    }

    func list(_ directory: String) async throws -> [FileEntry] { [textEntry, imageEntry] }
    func read(_ path: String) async throws -> String { text }
    func preview(_ path: String) async throws -> FilePreview {
        path == imageEntry.path ? .image(image) : .text(text, truncated: false)
    }
    func mkdir(_ path: String) async throws {}
    func rename(_ path: String, to name: String) async throws {}
    func trash(_ path: String) async throws {}
    func upload(_ local: URL, to directory: String, progress: @escaping @MainActor (Double) -> Void) async throws {}
    func download(_ path: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL { URL(filePath: "/dev/null") }
    func watch(_ directory: String, onChange: @escaping @MainActor () -> Void) async -> FileWatch? { nil }
}

final class MinifiedDiff: DiffSource {
    let title = "Working tree vs HEAD"
    let unavailableReason: String? = nil
    let text: String

    init(text: String) { self.text = text }

    func repository() async throws -> DiffRepository {
        DiffRepository(root: "~/site", branch: "main", ahead: 0, behind: 0, changedFiles: 1)
    }
    func files(_ scope: DiffScope) async throws -> [DiffFile] {
        [DiffFile(path: "bundle.min.js", status: .modified, additions: 1, deletions: 1, hunks: [
            DiffHunk(id: 0, header: "@@ -1 +1 @@", lines: [
                DiffLine(id: 0, kind: .removed, oldNumber: 1, newNumber: nil, text: text),
                DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 1, text: text + "x"),
            ]),
        ])]
    }
    func turns() async throws -> [DiffTurn] { [] }
    func reviewer(for scope: DiffScope) -> String? { nil }
    func sendReview(_ notes: [ReviewNote], scope: DiffScope, preamble: String?) async throws {}
}
