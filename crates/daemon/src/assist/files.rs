//! D7: fuzzy file search under a directory, for `@` mentions in agent prompts.
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

/// Cached listings.
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
                let Ok(rel) = entry.path().strip_prefix(root) else {
                    return WalkState::Continue;
                };
                let kind = match entry.file_type() {
                    Some(t) if t.is_dir() => FileKind::Dir,
                    Some(t) if t.is_symlink() => FileKind::Symlink,
                    Some(t) if t.is_file() => FileKind::File,
                    _ => FileKind::Other,
                };
                let path = rel
                    .components()
                    .map(|c| c.as_os_str().to_string_lossy())
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
    let fold = |c: char| {
        if sensitive { c } else { c.to_ascii_lowercase() }
    };
    let q: Vec<char> = query
        .chars()
        .filter(|c| !c.is_whitespace())
        .map(fold)
        .collect();
    let p: Vec<char> = path.chars().collect();
    if q.is_empty() {
        return Some((-(p.len() as i64), Vec::new()));
    }
    // Forward pass: the earliest end of a match.
    let mut qi = 0;
    let mut end = None;
    for (i, &c) in p.iter().enumerate() {
        if fold(c) == q[qi] {
            qi += 1;
            if qi == q.len() {
                end = Some(i);
                break;
            }
        }
    }
    let end = end?;
    // Backward pass from there: the tightest match ending at `end`.
    let mut positions = vec![0u32; q.len()];
    let mut qi = q.len();
    for i in (0..=end).rev() {
        if qi > 0 && fold(p[i]) == q[qi - 1] {
            qi -= 1;
            positions[qi] = i as u32;
        }
    }
    // Prefer the same characters in the file name when they appear there.
    let name_start = p.iter().rposition(|&c| c == '/').map_or(0, |i| i + 1);
    if let Some(in_name) = match_from(&p, &q, name_start, fold) {
        positions = in_name;
    }

    let boundary = |i: usize| {
        i == 0 || {
            let prev = p[i - 1];
            prev == '/' || "_-. ".contains(prev) || (prev.is_lowercase() && p[i].is_uppercase())
        }
    };
    let mut score: i64 = 0;
    for (k, &pos) in positions.iter().enumerate() {
        let i = pos as usize;
        score += 16;
        if i == 0 || p[i - 1] == '/' {
            score += 12;
        } else if boundary(i) {
            score += 8;
        }
        if k > 0 && positions[k - 1] + 1 == pos {
            score += 6;
        }
    }
    let span = (positions[q.len() - 1] - positions[0]) as i64 + 1;
    score -= (span - q.len() as i64).min(40);
    if positions[0] as usize >= name_start {
        score += 20;
        if positions[0] as usize == name_start {
            score += 10;
        }
    }
    score -= p.len() as i64 / 16;
    Some((score, positions))
}

/// A match of all of `q` inside `p[from..]`, greedy.
fn match_from(
    p: &[char],
    q: &[char],
    from: usize,
    fold: impl Fn(char) -> char,
) -> Option<Vec<u32>> {
    let mut out = Vec::with_capacity(q.len());
    let mut qi = 0;
    for (i, &c) in p.iter().enumerate().skip(from) {
        if qi < q.len() && fold(c) == q[qi] {
            out.push(i as u32);
            qi += 1;
        }
    }
    (qi == q.len()).then_some(out)
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
            .filter_map(|p| fuzzy("conn", p).map(|(s, _)| (s, *p)))
            .collect();
        scored.sort_by_key(|s| std::cmp::Reverse(s.0));
        assert_eq!(scored[0].1, "src/daemon/conn.rs");
        assert!(fuzzy("xyz", "src/conn.rs").is_none());
        let (_, pos) = fuzzy("dc", "src/daemon/conn.rs").unwrap();
        assert_eq!(pos, vec![4, 11]);
        // Smart case.
        assert!(fuzzy("Conn", "src/conn.rs").is_none());
        assert!(fuzzy("Conn", "src/Conn.rs").is_some());
    }

    #[test]
    fn walk_respects_gitignore_and_hidden_files() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        std::fs::write(d.join(".gitignore"), "target/\n*.log\n").unwrap();
        for f in [
            "src/main.rs",
            "src/lib.rs",
            "target/debug/app",
            "build.log",
            ".env",
            "README.md",
        ] {
            let p = d.join(f);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, "").unwrap();
        }
        let index = FileIndex::default();
        let all = index.search(d, "", 100);
        let paths: Vec<_> = all.matches.iter().map(|m| m.path.as_str()).collect();
        assert!(
            paths.contains(&"src/main.rs") && paths.contains(&"README.md"),
            "{paths:?}"
        );
        assert!(paths.contains(&"src"));
        assert!(
            !paths
                .iter()
                .any(|p| p.starts_with("target") || p.ends_with(".log"))
        );
        assert!(!paths.contains(&".env"));
        let hit = index.search(d, "mainrs", 5);
        assert_eq!(hit.matches[0].path, "src/main.rs");
        assert_eq!(hit.matches[0].kind, FileKind::File);
    }
}
