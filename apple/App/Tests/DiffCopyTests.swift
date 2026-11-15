import XCTest
@testable import App

/// Copying from the diff review: the whole diff, and the lines picked by their numbers.
final class DiffCopyTests: XCTestCase {
    private let modified = DiffFile(
        path: "src/lib.rs", status: .modified, additions: 2, deletions: 1,
        hunks: [DiffHunk(id: 0, header: "@@ -1,3 +1,4 @@ fn main", lines: [
            DiffLine(id: 0, kind: .context, oldNumber: 1, newNumber: 1, text: "fn main() {"),
            DiffLine(id: 1, kind: .removed, oldNumber: 2, newNumber: nil, text: "    old();"),
            DiffLine(id: 2, kind: .added, oldNumber: nil, newNumber: 2, text: "    new();"),
            DiffLine(id: 3, kind: .added, oldNumber: nil, newNumber: 3, text: "    more();"),
            DiffLine(id: 4, kind: .context, oldNumber: 3, newNumber: 4, text: "}"),
        ])])

    func testCopyDiffIsAUnifiedDiff() {
        let added = DiffFile(
            path: "NEW.md", status: .untracked, additions: 1, deletions: 0,
            hunks: [DiffHunk(id: 0, header: "@@ -0,0 +1,1 @@", lines: [DiffLine(id: 0, kind: .added, oldNumber: nil, newNumber: 1, text: "hi")])])
        let renamed = DiffFile(path: "b.png", status: .renamed, additions: 0, deletions: 0, hunks: [], oldPath: "a.png", isBinary: true)
        XCTAssertEqual(UnifiedDiff.text([modified, added, renamed]), """
            diff --git a/src/lib.rs b/src/lib.rs
            --- a/src/lib.rs
            +++ b/src/lib.rs
            @@ -1,3 +1,4 @@ fn main
             fn main() {
            -    old();
            +    new();
            +    more();
             }
            diff --git a/NEW.md b/NEW.md
            new file mode 100644
            --- /dev/null
            +++ b/NEW.md
            @@ -0,0 +1,1 @@
            +hi
            diff --git a/a.png b/b.png
            rename from a.png
            rename to b.png
            Binary files a/a.png and b/b.png differ

            """)
    }

    func testPickedLinesCopyAsTheFileHasThem() throws {
        var picked = try XCTUnwrap(DiffLineSelection.picking(
            modified.hunks[0].lines[1], fileId: modified.id, side: nil, extending: false, current: nil))
        picked = try XCTUnwrap(DiffLineSelection.picking(
            modified.hunks[0].lines[3], fileId: modified.id, side: nil, extending: true, current: picked))
        XCTAssertEqual(picked.text(in: modified), "    old();\n    new();\n    more();")
        XCTAssertTrue(picked.contains(modified.hunks[0].lines[2], fileId: modified.id, side: nil))
        XCTAssertFalse(picked.contains(modified.hunks[0].lines[4], fileId: modified.id, side: nil))

        let fresh = DiffLineSelection.picking(modified.hunks[0].lines[0], fileId: modified.id, side: nil, extending: false, current: picked)
        XCTAssertEqual(fresh?.lineIds, 0...0, "a plain click starts again")
        XCTAssertNil(DiffLineSelection.picking(modified.hunks[0].lines[0], fileId: modified.id, side: nil, extending: true, current: fresh))
    }

    func testSideBySideCopiesOnlyTheColumnPicked() throws {
        let lines = modified.hunks[0].lines
        let old = DiffLineSelection(fileId: modified.id, side: .old, anchor: lines[0].id, head: lines[4].id)
        XCTAssertEqual(old.text(in: modified), "fn main() {\n    old();\n}")
        let new = DiffLineSelection(fileId: modified.id, side: .new, anchor: lines[0].id, head: lines[4].id)
        XCTAssertEqual(new.text(in: modified), "fn main() {\n    new();\n    more();\n}")
        XCTAssertFalse(new.contains(lines[1], fileId: modified.id, side: .new))
        XCTAssertFalse(new.contains(lines[2], fileId: modified.id, side: .old))
    }
}
