import XCTest
@testable import App

final class FileListingRowsTests: XCTestCase {
    private func entry(_ path: String, folder: Bool = false) -> FileEntry {
        FileEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: folder)
    }

    func testFoldersComeFirstInFindersNameOrder() {
        let sorted = FileListingRows.sorted([
            entry("~/b10.txt"), entry("~/src", folder: true), entry("~/b2.txt"), entry("~/Apps", folder: true), entry("~/a.txt"),
        ])
        XCTAssertEqual(sorted.map(\.name), ["Apps", "src", "a.txt", "b2.txt", "b10.txt"])
    }

    func testRowsKeepTheSortedOrderAndNestExpandedFolders() {
        let root = FileListingRows.sorted([entry("~/z.txt"), entry("~/src", folder: true), entry("~/docs", folder: true)])
        let source = FileListingRows.sorted([entry("~/src/main.rs"), entry("~/src/lib.rs")])
        let rows = FileListingRows.rows(root, filter: "", expanded: ["~/src"], listings: ["~/src": source, "~/docs": [entry("~/docs/a.md")]])
        XCTAssertEqual(rows.map(\.id), ["~/docs", "~/src", "~/src/lib.rs", "~/src/main.rs", "~/z.txt"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1, 0])
    }

    func testAFilterMatchesTheFoldersOwnEntries() {
        let root = FileListingRows.sorted([entry("~/Main.swift"), entry("~/src", folder: true), entry("~/domain.rs")])
        let rows = FileListingRows.rows(root, filter: " MAIN ", expanded: ["~/src"], listings: ["~/src": [entry("~/src/main.rs")]])
        XCTAssertEqual(rows.map(\.id), ["~/domain.rs", "~/Main.swift"])
    }

    func testAListingIsSortedOffTheMainThread() async {
        let names = (0..<10_000).map { "file \(10_000 - $0).txt" }
        let sorted = await FileListingRows.sortedInBackground(names.map { entry("~/\($0)") })
        XCTAssertEqual(sorted.first?.name, "file 1.txt")
        XCTAssertEqual(sorted.last?.name, "file 10000.txt")
    }
}
