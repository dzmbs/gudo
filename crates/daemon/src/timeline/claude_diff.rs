use proto::{DiffLine, FileChange, FileDiff, Hunk, LineKind};

use super::claude_record::{Patch, ResultKind, RichResult};

const PREVIEW_LINES_LIMIT: usize = 6;
const LINE_CHARS_LIMIT: usize = 512;

#[derive(Default)]
struct Preview {
    additions: u32,
    deletions: u32,
    retained: usize,
    omitted: bool,
}

pub(super) fn result_diff(result: &RichResult) -> Vec<FileDiff> {
    let Some(path) = &result.file_path else {
        return Vec::new();
    };
    let created = matches!(result.kind, ResultKind::Create);
    if result.structured_patch.is_none() && !created {
        return Vec::new();
    }
    let mut preview = Preview::default();
    let mut hunks = result
        .structured_patch
        .iter()
        .flatten()
        .filter_map(|patch| preview.hunk(patch))
        .collect::<Vec<_>>();
    if created && hunks.is_empty() {
        hunks.push(preview.created(result.content.as_deref().unwrap_or_default()));
    }
    vec![FileDiff {
        path: path.clone(),
        old_path: None,
        change: if created {
            FileChange::Added
        } else {
            FileChange::Modified
        },
        binary: false,
        additions: preview.additions,
        deletions: preview.deletions,
        hunks,
        hunks_omitted: preview.omitted,
    }]
}

impl Preview {
    fn line(&mut self, line: &str) -> Option<DiffLine> {
        let (kind, text) = match line.as_bytes().first() {
            Some(b'+') => {
                self.additions = self.additions.saturating_add(1);
                (LineKind::Added, &line[1..])
            }
            Some(b'-') => {
                self.deletions = self.deletions.saturating_add(1);
                (LineKind::Removed, &line[1..])
            }
            Some(b' ') => (LineKind::Context, &line[1..]),
            _ => (LineKind::Context, line),
        };
        if self.retained >= PREVIEW_LINES_LIMIT {
            self.omitted = true;
            return None;
        }
        self.retained += 1;
        Some(DiffLine {
            kind,
            text: self.line_text(text),
        })
    }

    fn line_text(&mut self, text: &str) -> String {
        let mut characters = text.chars();
        let preview = characters.by_ref().take(LINE_CHARS_LIMIT).collect();
        self.omitted |= characters.next().is_some();
        preview
    }

    fn hunk(&mut self, patch: &Patch) -> Option<Hunk> {
        let lines = patch
            .lines
            .iter()
            .filter_map(|line| self.line(line))
            .collect::<Vec<_>>();
        if lines.is_empty() {
            return None;
        }
        Some(Hunk {
            old_start: patch.old_start,
            old_lines: patch.old_lines,
            new_start: patch.new_start,
            new_lines: patch.new_lines,
            header: String::new(),
            lines,
        })
    }

    fn created(&mut self, content: &str) -> Hunk {
        self.additions = u32::try_from(content.lines().count()).unwrap_or(u32::MAX);
        let lines = content
            .lines()
            .take(PREVIEW_LINES_LIMIT)
            .map(|line| DiffLine {
                kind: LineKind::Added,
                text: self.line_text(line),
            })
            .collect();
        self.omitted |= self.additions as usize > PREVIEW_LINES_LIMIT;
        Hunk {
            old_start: 0,
            old_lines: 0,
            new_start: 1,
            new_lines: self.additions,
            header: String::new(),
            lines,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncated_patch_lines_mark_the_diff_as_incomplete() {
        for (length, omitted) in [(512, false), (513, true)] {
            let result = RichResult {
                file_path: Some("/fixture/file".into()),
                structured_patch: Some(vec![Patch {
                    lines: vec![format!("+{}", "🦀".repeat(length))],
                    ..Patch::default()
                }]),
                ..RichResult::default()
            };
            let files = result_diff(&result);
            assert_eq!(files[0].hunks[0].lines[0].text.chars().count(), 512);
            assert_eq!(files[0].hunks_omitted, omitted);
        }
    }

    #[test]
    fn truncated_created_lines_mark_the_diff_as_incomplete() {
        for (length, omitted) in [(512, false), (513, true)] {
            let result = RichResult {
                file_path: Some("/fixture/file".into()),
                kind: ResultKind::Create,
                content: Some("🦀".repeat(length)),
                ..RichResult::default()
            };
            let files = result_diff(&result);
            assert_eq!(files[0].hunks[0].lines[0].text.chars().count(), 512);
            assert_eq!(files[0].hunks_omitted, omitted);
        }
    }
}
