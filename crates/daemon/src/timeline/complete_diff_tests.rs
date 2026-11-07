use super::*;

fn created(content: &str) -> RichResult {
    RichResult {
        file_path: Some("/fixture/file".into()),
        kind: ResultKind::Create,
        content: Some(content.into()),
        ..RichResult::default()
    }
}

#[test]
fn recorded_changes_keep_lines_and_text_beyond_the_inline_preview() {
    let text = "🦀".repeat(700);
    let lines = std::iter::repeat_n(format!("+{text}"), 20).collect();
    let result = RichResult {
        file_path: Some("/fixture/file".into()),
        structured_patch: Some(vec![Patch {
            old_start: 0,
            old_lines: 0,
            new_start: 1,
            new_lines: 20,
            lines,
        }]),
        ..RichResult::default()
    };
    let files = recorded_diff(&result).unwrap();
    assert_eq!(files[0].hunks[0].lines.len(), 20);
    assert_eq!(files[0].hunks[0].lines[0].text, text);
    assert_eq!((files[0].additions, files[0].deletions), (20, 0));
    assert!(!files[0].hunks_omitted);
}

#[test]
fn created_files_keep_their_exact_recorded_eof_state() {
    for (content, markers) in [("one\nlast\n", 0), ("one\nlast", 1)] {
        let files = recorded_diff(&created(content)).unwrap();
        let hunk = &files[0].hunks[0];
        assert_eq!(hunk.new_lines, 2);
        assert_eq!(files[0].additions, 2);
        assert_eq!(hunk.lines.len(), 2 + markers);
        if markers != 0 {
            assert_eq!(hunk.lines[2].kind, LineKind::NoNewline);
            assert!(hunk.lines[2].text.is_empty());
        }
    }
    let empty = recorded_diff(&created("")).unwrap();
    assert!(empty[0].hunks.is_empty());
    assert!(!empty[0].hunks_omitted);
}

#[test]
fn oversized_recorded_values_fail_instead_of_becoming_another_preview() {
    assert!(recorded_diff(&created(&"x".repeat(LINE_BYTES_LIMIT))).is_ok());
    assert!(recorded_diff(&created(&"x".repeat(LINE_BYTES_LIMIT + 1))).is_err());
    assert!(recorded_diff(&created(&"line\n".repeat(LINES_LIMIT + 1))).is_err());
    let mut builder = Builder::default();
    assert!(builder.charge(VALUE_BYTES_LIMIT).is_ok());
    assert!(builder.charge(1).is_err());
    assert_eq!(builder.bytes, VALUE_BYTES_LIMIT);
}

#[test]
fn hunk_count_is_admitted_before_expanding_the_next_hunk() {
    for (count, accepted) in [(HUNKS_LIMIT, true), (HUNKS_LIMIT + 1, false)] {
        let result = RichResult {
            file_path: Some("/fixture/file".into()),
            structured_patch: Some((0..count).map(|_| Patch::default()).collect()),
            ..RichResult::default()
        };
        assert_eq!(recorded_diff(&result).is_ok(), accepted);
    }
}

#[test]
fn unknown_change_kinds_and_invalid_patch_coordinates_do_not_gain_familiar_semantics() {
    let mut empty_path = created("line");
    empty_path.file_path = Some(String::new());
    assert!(recorded_diff(&empty_path).is_err());
    for kind in ["future-change", "missing"] {
        let result: RichResult = serde_json::from_value(serde_json::json!({
            "type": kind, "filePath": "/fixture/file", "structuredPatch": []
        }))
        .unwrap();
        assert!(recorded_diff(&result).is_err());
    }
    for lines in [
        vec!["+one"],
        vec!["unknown prefix"],
        vec![r"\ No newline at end of file"],
        vec![
            "+one",
            r"\ No newline at end of file",
            r"\ No newline at end of file",
        ],
    ] {
        let result = RichResult {
            file_path: Some("/fixture/file".into()),
            structured_patch: Some(vec![Patch {
                lines: lines.into_iter().map(str::to_owned).collect(),
                ..Patch::default()
            }]),
            ..RichResult::default()
        };
        assert!(recorded_diff(&result).is_err());
    }
}
