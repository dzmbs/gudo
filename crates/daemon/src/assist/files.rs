//! Fuzzy file search under a directory, for `@` mentions in agent prompts.
//!
//! The tree is walked with the `ignore` crate (ripgrep's walker): `.gitignore`, `.ignore`,
//! the global git excludes and hidden files are respected, in parallel. The listing is cached
//! per root for [`TTL`] and capped at [`MAX_FILES`] paths. Queries are matched as ordered
//! subsequences of the relative path (smart case) and scored fzf-style: matches at the start
//! of a path segment or word, consecutive runs, and matches inside the file name score higher;
//! gaps and long paths lower.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use proto::{FileKind, FileMatch, FileMatches};

use crate::core::lock;

/// Listings are reused this long.
pub(crate) const TTL: Duration = Duration::from_secs(10);
/// Paths listed per root at most.
pub(crate) const MAX_FILES: usize = 200_000;
/// Matches returned at most.
const MAX_LIMIT: usize = 200;

#[derive(Debug)]
struct Listing {
    /// Relative paths (`/`-separated) and kinds.
    paths: Vec<(String, FileKind)>,
    truncated: bool,
}

#[derive(Default)]
pub(crate) struct FileIndex {
    cache: Mutex<HashMap<PathBuf, (Instant, Arc<Listing>)>>,
}

impl FileIndex {
    /// Searches `root` (already checked against the path policy) for `query`.
    pub fn search(&self, root: &Path, query: &str, limit: usize) -> FileMatches {
        let listing = self.listing(root);
        let limit = limit.clamp(1, MAX_LIMIT);
        let mut hits: Vec<(i64, &(String, FileKind), Vec<u32>)> = listing
            .paths
            .iter()
            .filter_map(|entry| {
                let (score, positions) = fuzzy(query, &entry.0)?;
                Some((score, entry, positions))
            })
            .collect();
        hits.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then_with(|| a.1.0.len().cmp(&b.1.0.len()))
                .then_with(|| a.1.0.cmp(&b.1.0))
        });
        FileMatches {
            root: root.to_string_lossy().into_owned(),
            matches: hits
                .into_iter()
                .take(limit)
                .map(|(_, (path, kind), positions)| FileMatch {
                    path: path.clone(),
                    kind: *kind,
                    positions,
                })
                .collect(),
            scanned: listing.paths.len() as u32,
            truncated: listing.truncated,
        }
    }

    fn listing(&self, root: &Path) -> Arc<Listing> {
        if let Some((at, listing)) = lock(&self.cache).get(root)
            && at.elapsed() < TTL
        {
            return Arc::clone(listing);
        }
        let listing = Arc::new(walk(root));
        let mut cache = lock(&self.cache);
        cache.retain(|_, (at, _)| at.elapsed() < TTL);
        cache.insert(root.to_owned(), (Instant::now(), Arc::clone(&listing)));
        listing
    }
}

fn walk(root: &Path) -> Listing {
    let found = Mutex::new(Vec::new());
    let truncated = std::sync::atomic::AtomicBool::new(false);
    ignore::WalkBuilder::new(root)
        .hidden(true)
        .git_ignore(true)
        .git_global(true)
        .git_exclude(true)
        .require_git(false)
        .follow_links(false)
        .build_parallel()
        .run(|| {
            let found = &found;
            let truncated = &truncated;
            Box::new(move |entry| {
                use ignore::WalkState;
                let Ok(entry) = entry else {
                    return WalkState::Continue;
                };
                if entry.depth() == 0 {
                    return WalkState::Continue;
                }
                let Ok(relative) = entry.path().strip_prefix(root) else {
                    return WalkState::Continue;
                };
                let kind = match entry.file_type() {
                    Some(file_type) if file_type.is_dir() => FileKind::Dir,
                    Some(file_type) if file_type.is_symlink() => FileKind::Symlink,
                    Some(file_type) if file_type.is_file() => FileKind::File,
                    _ => FileKind::Other,
                };
                let path = relative
                    .components()
                    .map(|component| component.as_os_str().to_string_lossy())
                    .collect::<Vec<_>>()
                    .join("/");
                let mut found = lock(found);
                if found.len() >= MAX_FILES {
                    truncated.store(true, std::sync::atomic::Ordering::Relaxed);
                    return WalkState::Quit;
                }
                found.push((path, kind));
                WalkState::Continue
            })
        });
    let mut paths = found
        .into_inner()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    paths.sort_unstable_by(|a, b| a.0.cmp(&b.0));
    Listing {
        paths,
        truncated: truncated.into_inner(),
    }
}

/// Scores `path` against `query`: `None` unless every query character appears in order.
/// Returns the score and the matched character positions.
pub(crate) fn fuzzy(query: &str, path: &str) -> Option<(i64, Vec<u32>)> {
    let sensitive = query.chars().any(char::is_uppercase);
    let fold = |character: char| {
        if sensitive {
            character
        } else {
            character.to_ascii_lowercase()
        }
    };
    let query_chars: Vec<char> = query
        .chars()
        .filter(|character| !character.is_whitespace())
        .map(fold)
        .collect();
    let path_chars: Vec<char> = path.chars().collect();
    if query_chars.is_empty() {
        return Some((-(path_chars.len() as i64), Vec::new()));
    }
    // Forward pass: the earliest end of a match.
    let mut matched = 0;
    let mut end = None;
    for (i, &character) in path_chars.iter().enumerate() {
        if fold(character) == query_chars[matched] {
            matched += 1;
            if matched == query_chars.len() {
                end = Some(i);
                break;
            }
        }
    }
    let end = end?;
    // Backward pass from there: the tightest match ending at `end`.
    let mut positions = vec![0u32; query_chars.len()];
    let mut matched = query_chars.len();
    for i in (0..=end).rev() {
        if matched > 0 && fold(path_chars[i]) == query_chars[matched - 1] {
            matched -= 1;
            positions[matched] = i as u32;
        }
    }
    // Prefer the same characters in the file name when they appear there.
    let name_start = path_chars
        .iter()
        .rposition(|&character| character == '/')
        .map_or(0, |i| i + 1);
    if let Some(in_name) = match_from(&path_chars, &query_chars, name_start, fold) {
        positions = in_name;
    }

    let boundary = |i: usize| {
        i == 0 || {
            let previous = path_chars[i - 1];
            previous == '/'
                || "_-. ".contains(previous)
                || (previous.is_lowercase() && path_chars[i].is_uppercase())
        }
    };
    let mut score: i64 = 0;
    for (index, &position) in positions.iter().enumerate() {
        let i = position as usize;
        score += 16;
        if i == 0 || path_chars[i - 1] == '/' {
            score += 12;
        } else if boundary(i) {
            score += 8;
        }
        if index > 0 && positions[index - 1] + 1 == position {
            score += 6;
        }
    }
    let span = (positions[query_chars.len() - 1] - positions[0]) as i64 + 1;
    score -= (span - query_chars.len() as i64).min(40);
    if positions[0] as usize >= name_start {
        score += 20;
        if positions[0] as usize == name_start {
            score += 10;
        }
    }
    score -= path_chars.len() as i64 / 16;
    Some((score, positions))
}

/// A match of all of `query_chars` inside `path_chars[from..]`, greedy.
fn match_from(
    path_chars: &[char],
    query_chars: &[char],
    from: usize,
    fold: impl Fn(char) -> char,
) -> Option<Vec<u32>> {
    let mut positions = Vec::with_capacity(query_chars.len());
    let mut matched = 0;
    for (i, &character) in path_chars.iter().enumerate().skip(from) {
        if matched < query_chars.len() && fold(character) == query_chars[matched] {
            positions.push(i as u32);
            matched += 1;
        }
    }
    (matched == query_chars.len()).then_some(positions)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_ranks_names_and_boundaries() {
        let paths = [
            "src/daemon/conn.rs",
            "docs/connectivity.md",
            "crates/client-core/src/conn.rs",
            "src/console.rs",
        ];
        let mut scored: Vec<_> = paths
            .iter()
            .filter_map(|path| fuzzy("conn", path).map(|(score, _)| (score, *path)))
            .collect();
        scored.sort_by_key(|entry| std::cmp::Reverse(entry.0));
        assert_eq!(scored[0].1, "src/daemon/conn.rs");
        assert!(fuzzy("xyz", "src/conn.rs").is_none());
        let (_, positions) = fuzzy("dc", "src/daemon/conn.rs").unwrap();
        assert_eq!(positions, vec![4, 11]);
        // Smart case.
        assert!(fuzzy("Conn", "src/conn.rs").is_none());
        assert!(fuzzy("Conn", "src/Conn.rs").is_some());
    }

    #[test]
    fn walk_respects_gitignore_and_hidden_files() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::write(root.join(".gitignore"), "target/\n*.log\n").unwrap();
        for name in [
            "src/main.rs",
            "src/lib.rs",
            "target/debug/app",
            "build.log",
            ".env",
            "README.md",
        ] {
            let path = root.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "").unwrap();
        }
        let index = FileIndex::default();
        let all = index.search(root, "", 100);
        let paths: Vec<_> = all
            .matches
            .iter()
            .map(|found| found.path.as_str())
            .collect();
        assert!(
            paths.contains(&"src/main.rs") && paths.contains(&"README.md"),
            "{paths:?}"
        );
        assert!(paths.contains(&"src"));
        assert!(
            !paths
                .iter()
                .any(|path| path.starts_with("target") || path.ends_with(".log"))
        );
        assert!(!paths.contains(&".env"));
        let hit = index.search(root, "mainrs", 5);
        assert_eq!(hit.matches[0].path, "src/main.rs");
        assert_eq!(hit.matches[0].kind, FileKind::File);
    }
}
