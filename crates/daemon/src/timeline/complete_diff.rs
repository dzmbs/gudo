use proto::{DiffLine, FileChange, FileDiff, Hunk, LineKind, WsError};

use super::claude_record::{Patch, ResultKind, RichResult};

#[cfg(test)]
#[path = "complete_diff_tests.rs"]
mod tests;

const VALUE_BYTES_LIMIT: usize = 1024 * 1024;
const LINE_BYTES_LIMIT: usize = 8192;
const LINES_LIMIT: usize = 20_000;
const HUNKS_LIMIT: usize = 512;

#[derive(Default)]
struct Builder {
    bytes: usize,
    lines: usize,
    hunks: usize,
    additions: u32,
    deletions: u32,
}

pub(super) fn recorded_diff(result: &RichResult) -> Result<Vec<FileDiff>, WsError> {
    let path = result
        .file_path
        .as_deref()
        .filter(|path| !path.is_empty())
        .ok_or_else(unavailable)?;
    let mut builder = Builder::default();
    builder.charge(path.len().saturating_mul(2).saturating_add(256))?;
    let (change, hunks) = match result.kind {
        ResultKind::Create => (
            FileChange::Added,
            builder.created(result.content.as_deref().ok_or_else(unavailable)?)?,
        ),
        ResultKind::Missing => {
            let patches = result.structured_patch.as_deref().ok_or_else(unavailable)?;
            let hunks = patches
                .iter()
                .map(|patch| builder.hunk(patch))
                .collect::<Result<_, _>>()?;
            (FileChange::Modified, hunks)
        }
        ResultKind::Other => return Err(unavailable()),
    };
    Ok(vec![FileDiff {
        path: path.to_owned(),
        old_path: None,
        change,
        binary: false,
        additions: builder.additions,
        deletions: builder.deletions,
        hunks,
        hunks_omitted: false,
    }])
}

impl Builder {
    fn charge(&mut self, bytes: usize) -> Result<(), WsError> {
        if bytes > VALUE_BYTES_LIMIT - self.bytes {
            return Err(too_large());
        }
        self.bytes += bytes;
        Ok(())
    }

    fn line(&mut self, kind: LineKind, text: &str) -> Result<DiffLine, WsError> {
        if self.lines == LINES_LIMIT || text.len() > LINE_BYTES_LIMIT {
            return Err(too_large());
        }
        self.charge(text.len().saturating_mul(2).saturating_add(128))?;
        self.lines += 1;
        self.additions += u32::from(kind == LineKind::Added);
        self.deletions += u32::from(kind == LineKind::Removed);
        Ok(DiffLine {
            kind,
            text: text.to_owned(),
        })
    }

    fn begin_hunk(&mut self) -> Result<(), WsError> {
        if self.hunks == HUNKS_LIMIT {
            return Err(too_large());
        }
        self.charge(256)?;
        self.hunks += 1;
        Ok(())
    }

    fn hunk(&mut self, patch: &Patch) -> Result<Hunk, WsError> {
        self.begin_hunk()?;
        let mut old_lines = 0;
        let mut new_lines = 0;
        let mut lines = Vec::new();
        for line in &patch.lines {
            let (kind, text) = match line.as_bytes().first() {
                Some(b'+') => (LineKind::Added, &line[1..]),
                Some(b'-') => (LineKind::Removed, &line[1..]),
                Some(b' ') => (LineKind::Context, &line[1..]),
                Some(b'\\')
                    if line == r"\ No newline at end of file"
                        && lines
                            .last()
                            .is_some_and(|line: &DiffLine| line.kind != LineKind::NoNewline) =>
                {
                    (LineKind::NoNewline, "")
                }
                None => (LineKind::Context, ""),
                _ => return Err(unavailable()),
            };
            old_lines += u32::from(matches!(kind, LineKind::Context | LineKind::Removed));
            new_lines += u32::from(matches!(kind, LineKind::Context | LineKind::Added));
            lines.push(self.line(kind, text)?);
        }
        if old_lines != patch.old_lines || new_lines != patch.new_lines {
            return Err(unavailable());
        }
        Ok(Hunk {
            old_start: patch.old_start,
            old_lines,
            new_start: patch.new_start,
            new_lines,
            header: String::new(),
            lines,
        })
    }

    fn created(&mut self, content: &str) -> Result<Vec<Hunk>, WsError> {
        if content.is_empty() {
            return Ok(Vec::new());
        }
        self.begin_hunk()?;
        let mut lines = content
            .split_terminator('\n')
            .map(|text| self.line(LineKind::Added, text))
            .collect::<Result<Vec<_>, _>>()?;
        let new_lines = self.additions;
        if !content.ends_with('\n') {
            lines.push(self.line(LineKind::NoNewline, "")?);
        }
        Ok(vec![Hunk {
            old_start: 0,
            old_lines: 0,
            new_start: 1,
            new_lines,
            header: String::new(),
            lines,
        }])
    }
}

fn unavailable() -> WsError {
    WsError::Unavailable("Complete recorded changes are unavailable. Open Terminal.".into())
}

fn too_large() -> WsError {
    WsError::Unavailable("These recorded changes are too large for Chat. Open Terminal.".into())
}
