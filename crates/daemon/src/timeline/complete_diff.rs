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

/// One file's complete recorded change: a unified diff of an update, or a file's whole text
/// when it was added or deleted. All files of one change share the value allowance.
pub(crate) enum RecordedFile<'a> {
    Added {
        path: &'a str,
        content: &'a str,
    },
    Deleted {
        path: &'a str,
        content: &'a str,
    },
    Updated {
        path: &'a str,
        old_path: Option<&'a str>,
        unified: &'a str,
    },
}

pub(crate) fn recorded_files(files: &[RecordedFile<'_>]) -> Result<Vec<FileDiff>, WsError> {
    let mut builder = Builder::default();
    files
        .iter()
        .map(|file| {
            let (additions, deletions) = (builder.additions, builder.deletions);
            let (path, old_path, change, hunks) = match file {
                RecordedFile::Added { path, content } => {
                    (*path, None, FileChange::Added, builder.created(content)?)
                }
                RecordedFile::Deleted { path, content } => {
                    let mut hunks = builder.created(content)?;
                    for hunk in &mut hunks {
                        (hunk.old_start, hunk.new_start) = (hunk.new_start, 0);
                        hunk.old_lines = std::mem::take(&mut hunk.new_lines);
                        for line in &mut hunk.lines {
                            if line.kind == LineKind::Added {
                                line.kind = LineKind::Removed;
                            }
                        }
                    }
                    builder.deletions += builder.additions - additions;
                    builder.additions = additions;
                    (*path, None, FileChange::Deleted, hunks)
                }
                RecordedFile::Updated {
                    path,
                    old_path,
                    unified,
                } => {
                    let hunks = patches(unified)?
                        .iter()
                        .map(|patch| builder.hunk(patch))
                        .collect::<Result<_, _>>()?;
                    let change = if old_path.is_some() {
                        FileChange::Renamed
                    } else {
                        FileChange::Modified
                    };
                    (*path, *old_path, change, hunks)
                }
            };
            builder.charge(path.len().saturating_mul(2).saturating_add(256))?;
            Ok(FileDiff {
                path: path.to_owned(),
                old_path: old_path.map(str::to_owned),
                change,
                binary: false,
                additions: builder.additions - additions,
                deletions: builder.deletions - deletions,
                hunks,
                hunks_omitted: false,
            })
        })
        .collect()
}

/// The hunks of a unified diff; file headers before the first hunk are passed over.
fn patches(unified: &str) -> Result<Vec<Patch>, WsError> {
    let mut patches: Vec<Patch> = Vec::new();
    for line in unified.lines() {
        if let Some(ranges) = line
            .strip_prefix("@@ -")
            .and_then(|rest| rest.split_once(" @@"))
        {
            let (old, new) = ranges.0.split_once(" +").ok_or_else(unavailable)?;
            let range = |range: &str| -> Option<(u32, u32)> {
                match range.split_once(',') {
                    Some((start, lines)) => Some((start.parse().ok()?, lines.parse().ok()?)),
                    None => Some((range.parse().ok()?, 1)),
                }
            };
            let (old_start, old_lines) = range(old).ok_or_else(unavailable)?;
            let (new_start, new_lines) = range(new).ok_or_else(unavailable)?;
            patches.push(Patch {
                lines: Vec::new(),
                old_start,
                old_lines,
                new_start,
                new_lines,
            });
        } else if let Some(patch) = patches.last_mut() {
            patch.lines.push(line.to_owned());
        }
    }
    if patches.is_empty() {
        return Err(unavailable());
    }
    Ok(patches)
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
        let before = self.additions;
        let mut lines = content
            .split_terminator('\n')
            .map(|text| self.line(LineKind::Added, text))
            .collect::<Result<Vec<_>, _>>()?;
        let new_lines = self.additions - before;
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
