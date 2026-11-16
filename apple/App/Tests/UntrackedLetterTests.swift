import GudoCore
import XCTest
@testable import App

/// A file git does not track yet has the same letter in Changes as in Files: U.
@MainActor
final class UntrackedLetterTests: XCTestCase {
    func testChangesMarksUntrackedFilesAsFilesDoes() {
        let status = GudoCore.GitStatus(root: "/home/me/proj", branch: "main", head: "abc", upstream: nil, ahead: 0, behind: 0, files: [
            GitFileStatus(path: "new.txt", origPath: nil, staged: .unmodified, unstaged: .untracked),
            GitFileStatus(path: "README.md", origPath: nil, staged: .added, unstaged: .unmodified),
        ])
        let untracked = LiveDiffSource.untrackedPaths(status)
        let files = LiveDiffSource.markingUntracked([
            DiffFile(path: "new.txt", status: .added, additions: 1, deletions: 0, hunks: []),
            DiffFile(path: "README.md", status: .added, additions: 1, deletions: 0, hunks: []),
            DiffFile(path: "main.rs", status: .modified, additions: 1, deletions: 1, hunks: []),
        ], untracked: untracked)
        XCTAssertEqual(files.map(\.status), [.untracked, .added, .modified])
        XCTAssertEqual(files[0].status, FileEntry.GitStatus(status.files[0]), "the letter Files shows")
    }
}
