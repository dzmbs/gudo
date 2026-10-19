//! D5: completion candidates for a command line.
//!
//! The line is split into shell words (quotes, backslashes and the operators `; | & ( ) < >`
//! understood), and the word under the cursor is completed from, in order:
//!
//! 1. **history**: whole command lines starting with the line, ranked by frecency in the
//!    pane's directory (only with the cursor at the end of the line);
//! 2. **git**: subcommands after `git`, branches, remote branches and tags where a ref goes,
//!    changed and untracked files after `git add`/`restore`/`rm`/`diff`/…;
//! 3. **commands** on `$PATH` in command position (the pane shell's `PATH`, cached);
//! 4. **paths** relative to the pane's directory (`~` expanded; dot files only when the word
//!    starts with `.`), directories with a trailing `/`.
//!
//! Replacements are quoted for where the word is: inside `'…'` or `"…"`, or with backslashes.

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use proto::{Completion, CompletionKind, HistoryQuery};

use super::history::History;
use crate::core::lock;

/// Directory entries read per listing.
const MAX_DIR_ENTRIES: usize = 5000;
/// History lines offered.
const HISTORY_ITEMS: usize = 4;
/// `$PATH` listings are reused this long.
const PATH_TTL: Duration = Duration::from_secs(30);
/// Git refs and status are reused this long.
const GIT_TTL: Duration = Duration::from_secs(3);
/// No git subprocess once this much of the budget is gone.
const GIT_BUDGET: Duration = Duration::from_millis(90);

const GIT_SUBCOMMANDS: &[&str] = &[
    "add",
    "bisect",
    "blame",
    "branch",
    "checkout",
    "cherry-pick",
    "clone",
    "commit",
    "diff",
    "fetch",
    "grep",
    "init",
    "log",
    "merge",
    "mv",
    "pull",
    "push",
    "rebase",
    "remote",
    "reset",
    "restore",
    "revert",
    "rm",
    "show",
    "stash",
    "status",
    "switch",
    "tag",
    "worktree",
];
const GIT_REF_COMMANDS: &[&str] = &[
    "checkout",
    "switch",
    "merge",
    "rebase",
    "branch",
    "log",
    "diff",
    "show",
    "cherry-pick",
    "reset",
    "push",
    "pull",
    "fetch",
    "tag",
    "revert",
    "worktree",
];
const GIT_PATH_COMMANDS: &[&str] = &["add", "restore", "rm", "diff", "checkout", "stage", "mv"];
/// Words after which the next word is still a command (`sudo make`).
const PREFIX_COMMANDS: &[&str] = &[
    "sudo", "env", "time", "nohup", "exec", "command", "builtin", "nice", "xargs", "watch", "doas",
];

/// A cached value and when it was computed.
type Cached<T> = (Instant, std::sync::Arc<T>);

/// Caches shared by completion requests.
#[derive(Default)]
pub(crate) struct Caches {
    path: Mutex<HashMap<OsString, Cached<Vec<String>>>>,
    git: Mutex<HashMap<PathBuf, Cached<GitInfo>>>,
}

#[derive(Debug, Default)]
struct GitInfo {
    /// The work tree's top level.
    top: PathBuf,
    /// `(name, detail)`: branches, then tags, then remote branches.
    refs: Vec<(String, &'static str)>,
    /// Changed paths relative to the top level, with their status letters.
    changed: Vec<(String, String)>,
}

/// What a completion needs to know about the pane.
pub(crate) struct Context<'a> {
    pub cwd: Option<PathBuf>,
    pub home: PathBuf,
    pub path_var: Option<OsString>,
    pub history: &'a History,
    pub limit: usize,
}

/// A shell word.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Word {
    start: usize,
    end: usize,
    /// Unquoted text.
    text: String,
    /// The quote still open at the end of the word.
    open: Option<char>,
    command: bool,
    segment: usize,
}

/// Splits `chars` into words.
fn words(chars: &[char]) -> (Vec<Word>, bool, usize) {
    let mut out: Vec<Word> = Vec::new();
    let mut cur: Option<Word> = None;
    let mut quote: Option<char> = None;
    let mut escaped = false;
    let mut expect_command = true;
    let mut segment = 0;
    let finish = |cur: &mut Option<Word>, out: &mut Vec<Word>, expect: &mut bool| {
        if let Some(w) = cur.take() {
            let assignment = w.command
                && w.text.contains('=')
                && w.text.split('=').next().is_some_and(|n| {
                    !n.is_empty() && n.chars().all(|c| c.is_alphanumeric() || c == '_')
                });
            *expect = assignment || (w.command && PREFIX_COMMANDS.contains(&w.text.as_str()));
            out.push(w);
        }
    };
    for (i, &c) in chars.iter().enumerate() {
        if escaped {
            escaped = false;
            if let Some(w) = cur.as_mut() {
                w.text.push(c);
                w.end = i + 1;
            }
            continue;
        }
        if quote.is_none() && (c.is_whitespace() || ";|&()<>".contains(c)) {
            finish(&mut cur, &mut out, &mut expect_command);
            if ";|&(\n".contains(c) {
                expect_command = true;
                segment += 1;
            } else if "<>".contains(c) {
                expect_command = false;
            }
            continue;
        }
        let w = cur.get_or_insert_with(|| Word {
            start: i,
            end: i,
            text: String::new(),
            open: None,
            command: expect_command,
            segment,
        });
        w.end = i + 1;
        match (quote, c) {
            (None, '\\') => escaped = true,
            (Some('"'), '\\') => escaped = true,
            (None, '\'' | '"') => quote = Some(c),
            (Some(q), c) if c == q => quote = None,
            _ => w.text.push(c),
        }
        w.open = quote;
    }
    if escaped && let Some(w) = cur.as_mut() {
        w.text.push('\\');
    }
    finish(&mut cur, &mut out, &mut expect_command);
    (out, expect_command, segment)
}

/// Completes `line` at `cursor` (in chars).
pub(crate) fn complete(
    ctx: &Context<'_>,
    caches: &Caches,
    line: &str,
    cursor: usize,
) -> Vec<Completion> {
    let started = Instant::now();
    let chars: Vec<char> = line.chars().collect();
    let cursor = cursor.min(chars.len());
    let (all, _, _) = words(&chars);
    // The word under the cursor, as typed up to the cursor.
    let (head, expect, segment) = words(&chars[..cursor]);
    let current = match head.last() {
        Some(w) if w.end == cursor => w.clone(),
        _ => Word {
            start: cursor,
            end: cursor,
            text: String::new(),
            open: None,
            command: expect,
            segment,
        },
    };
    let end = all
        .iter()
        .find(|w| w.start == current.start)
        .map_or(cursor, |w| w.end.max(cursor));
    let before: Vec<&Word> = head
        .iter()
        .filter(|w| w.segment == current.segment && w.start < current.start)
        .collect();
    let mut items = Vec::new();

    // 1. History: whole lines.
    let trimmed = line.trim_start();
    if cursor == chars.len() && !trimmed.trim().is_empty() {
        let offset = chars.len() - trimmed.chars().count();
        let hits = ctx.history.query(&HistoryQuery {
            cwd: ctx.cwd.as_ref().map(|c| c.to_string_lossy().into_owned()),
            prefix: Some(trimmed.to_owned()),
            contains: None,
            since: None,
            limit: (HISTORY_ITEMS + 1) as u32,
        });
        items.extend(
            hits.into_iter()
                .filter(|h| h.command != trimmed)
                .take(HISTORY_ITEMS)
                .map(|h| Completion {
                    display: h.command.clone(),
                    text: h.command,
                    kind: CompletionKind::History,
                    detail: h.cwd,
                    start: offset as u32,
                    end: chars.len() as u32,
                }),
        );
    }

    let replace = |text: String, display: String, kind, detail: Option<String>| Completion {
        text,
        display,
        kind,
        detail,
        start: current.start as u32,
        end: end as u32,
    };
    let quote = |s: &str| quote_for(current.open, s);

    // 2. git.
    let git_cmd = before.first().filter(|w| w.text == "git" && w.command);
    if git_cmd.is_some() && !current.text.starts_with('-') {
        let sub = before.get(1).map(|w| w.text.as_str());
        match sub {
            None => items.extend(
                GIT_SUBCOMMANDS
                    .iter()
                    .filter(|s| s.starts_with(current.text.as_str()))
                    .map(|s| {
                        replace(
                            (*s).to_owned(),
                            (*s).to_owned(),
                            CompletionKind::Command,
                            None,
                        )
                    }),
            ),
            Some(sub) if started.elapsed() < GIT_BUDGET => {
                if let Some(info) = ctx.cwd.as_deref().and_then(|cwd| caches.git(cwd)) {
                    if GIT_REF_COMMANDS.contains(&sub) {
                        items.extend(
                            info.refs
                                .iter()
                                .filter(|(r, _)| r.starts_with(current.text.as_str()))
                                .map(|(r, kind)| {
                                    replace(
                                        quote(r),
                                        r.clone(),
                                        CompletionKind::GitRef,
                                        Some((*kind).to_owned()),
                                    )
                                }),
                        );
                    }
                    if GIT_PATH_COMMANDS.contains(&sub) {
                        for (path, status) in &info.changed {
                            let shown = match &ctx.cwd {
                                Some(cwd) => relative(&info.top.join(path), cwd),
                                None => path.clone(),
                            };
                            if shown.starts_with(current.text.as_str()) {
                                items.push(replace(
                                    quote(&shown),
                                    shown.clone(),
                                    CompletionKind::GitPath,
                                    Some(status.clone()),
                                ));
                            }
                        }
                    }
                }
            }
            Some(_) => {}
        }
    }

    // 3. Commands on $PATH.
    let pathlike = current.text.contains('/') || current.text.starts_with(['.', '~']);
    if current.command
        && !pathlike
        && !current.text.is_empty()
        && let Some(path_var) = &ctx.path_var
    {
        let names = caches.executables(path_var);
        let start = names.partition_point(|n| n.as_str() < current.text.as_str());
        items.extend(
            names[start..]
                .iter()
                .take_while(|n| n.starts_with(current.text.as_str()))
                .take(ctx.limit)
                .map(|n| replace(quote(n), n.clone(), CompletionKind::Command, None)),
        );
    }

    // 4. Paths.
    if (!current.command || pathlike) && !current.text.starts_with('-') {
        items.extend(paths(ctx, &chars, &current, end));
    }

    let mut seen = std::collections::HashSet::new();
    items.retain(|c| seen.insert((c.text.clone(), c.start, c.end)));
    items.truncate(ctx.limit);
    items
}

/// `path` relative to `base` when inside it, else absolute.
fn relative(path: &Path, base: &Path) -> String {
    path.strip_prefix(base)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| path.to_string_lossy().into_owned())
}

/// File and directory candidates for `word`.
fn paths(ctx: &Context<'_>, chars: &[char], word: &Word, end: usize) -> Vec<Completion> {
    let typed = &word.text;
    let (dir_part, base) = match typed.rfind('/') {
        Some(i) => (&typed[..=i], &typed[i + 1..]),
        None => ("", typed.as_str()),
    };
    let dir = if let Some(rest) = dir_part.strip_prefix("~/") {
        ctx.home.join(rest)
    } else if dir_part == "~" || typed == "~" {
        ctx.home.clone()
    } else if dir_part.starts_with('/') {
        PathBuf::from(dir_part)
    } else {
        match &ctx.cwd {
            Some(cwd) => cwd.join(dir_part),
            None => return Vec::new(),
        }
    };
    if typed == "~" {
        return vec![Completion {
            text: "~/".into(),
            display: "~/".into(),
            kind: CompletionKind::Dir,
            detail: None,
            start: word.start as u32,
            end: end as u32,
        }];
    }
    // The raw text up to and including the last `/` (or an opening quote), kept as typed.
    let raw: String = chars[word.start..word.end.min(chars.len())]
        .iter()
        .collect();
    let raw_dir: &str = match raw.rfind('/') {
        Some(i) => &raw[..=i],
        None if raw.starts_with(['\'', '"']) => &raw[..1],
        None => "",
    };
    let hidden = base.starts_with('.');
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut found: Vec<(String, bool)> = entries
        .take(MAX_DIR_ENTRIES)
        .filter_map(Result::ok)
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') && !hidden {
                return None;
            }
            let is_dir = e
                .file_type()
                .ok()
                .is_some_and(|t| t.is_dir() || (t.is_symlink() && e.path().is_dir()));
            Some((name, is_dir))
        })
        .collect();
    let exact: Vec<(String, bool)> = found
        .iter()
        .filter(|(n, _)| n.starts_with(base))
        .cloned()
        .collect();
    if exact.is_empty() {
        let lower = base.to_lowercase();
        found.retain(|(n, _)| n.to_lowercase().starts_with(&lower));
    } else {
        found = exact;
    }
    found.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    found
        .into_iter()
        .take(ctx.limit)
        .map(|(name, is_dir)| {
            let mut text = format!("{raw_dir}{}", quote_for(word.open, &name));
            if is_dir {
                text.push('/');
            }
            Completion {
                display: if is_dir { format!("{name}/") } else { name },
                text,
                kind: if is_dir {
                    CompletionKind::Dir
                } else {
                    CompletionKind::Path
                },
                detail: None,
                start: word.start as u32,
                end: end as u32,
            }
        })
        .collect()
}

/// Quotes `s` for insertion inside an open `'` or `"`, or with backslashes outside quotes.
fn quote_for(open: Option<char>, s: &str) -> String {
    match open {
        Some('\'') => s.replace('\'', r"'\''"),
        Some('"') => {
            let mut out = String::with_capacity(s.len());
            for c in s.chars() {
                if "\"\\$`".contains(c) {
                    out.push('\\');
                }
                out.push(c);
            }
            out
        }
        _ => {
            let mut out = String::with_capacity(s.len());
            for c in s.chars() {
                if c.is_whitespace() || "'\"\\$`!&|;()<>*?[]{}#~".contains(c) {
                    out.push('\\');
                }
                out.push(c);
            }
            out
        }
    }
}

impl Caches {
    /// Executables on `path_var`, sorted and deduplicated.
    fn executables(&self, path_var: &OsStr) -> std::sync::Arc<Vec<String>> {
        if let Some((at, names)) = lock(&self.path).get(path_var)
            && at.elapsed() < PATH_TTL
        {
            return std::sync::Arc::clone(names);
        }
        let mut names: Vec<String> = std::env::split_paths(path_var)
            .filter_map(|dir| std::fs::read_dir(dir).ok())
            .flat_map(|entries| entries.take(MAX_DIR_ENTRIES).filter_map(Result::ok))
            .filter(|e| {
                use std::os::unix::fs::PermissionsExt;
                e.path()
                    .metadata()
                    .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            })
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort_unstable();
        names.dedup();
        let names = std::sync::Arc::new(names);
        lock(&self.path).insert(
            path_var.to_owned(),
            (Instant::now(), std::sync::Arc::clone(&names)),
        );
        names
    }

    /// Refs and changed files of the repository containing `cwd`.
    fn git(&self, cwd: &Path) -> Option<std::sync::Arc<GitInfo>> {
        let top = cwd
            .ancestors()
            .find(|d| d.join(".git").exists())?
            .to_owned();
        if let Some((at, info)) = lock(&self.git).get(&top)
            && at.elapsed() < GIT_TTL
        {
            return Some(std::sync::Arc::clone(info));
        }
        let mut info = GitInfo {
            top: top.clone(),
            ..GitInfo::default()
        };
        if let Ok(out) = crate::ws::git::git(
            &top,
            &[
                "for-each-ref",
                "--format=%(refname)",
                "refs/heads",
                "refs/tags",
                "refs/remotes",
            ],
        ) {
            let text = String::from_utf8_lossy(&out);
            for full in text.lines() {
                let (name, kind) = if let Some(n) = full.strip_prefix("refs/heads/") {
                    (n, "branch")
                } else if let Some(n) = full.strip_prefix("refs/tags/") {
                    (n, "tag")
                } else if let Some(n) = full.strip_prefix("refs/remotes/") {
                    if n.ends_with("/HEAD") {
                        continue;
                    }
                    (n, "remote")
                } else {
                    continue;
                };
                info.refs.push((name.to_owned(), kind));
            }
            let rank = |k: &str| match k {
                "branch" => 0,
                "tag" => 1,
                _ => 2,
            };
            info.refs.sort_by_key(|(_, k)| rank(k));
        }
        if let Ok(out) = crate::ws::git::git(
            &top,
            &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
        ) {
            let mut fields = out.split(|&b| b == 0);
            while let Some(entry) = fields.next() {
                if entry.len() < 4 {
                    continue;
                }
                let status = String::from_utf8_lossy(&entry[..2]).trim().to_owned();
                let path = String::from_utf8_lossy(&entry[3..]).into_owned();
                // Renames carry the source path in the next field.
                if entry[0] == b'R' || entry[0] == b'C' {
                    fields.next();
                }
                info.changed.push((path, status));
            }
        }
        let info = std::sync::Arc::new(info);
        lock(&self.git).insert(top, (Instant::now(), std::sync::Arc::clone(&info)));
        Some(info)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_understand_quotes_and_operators() {
        let chars: Vec<char> = r#"FOO=1 sudo ls 'a b' "c\"d" | grep x\ y; cd"#.chars().collect();
        let (w, expect, _) = words(&chars);
        let texts: Vec<_> = w.iter().map(|w| (w.text.as_str(), w.command)).collect();
        assert_eq!(
            texts,
            vec![
                ("FOO=1", true),
                ("sudo", true),
                ("ls", true),
                ("a b", false),
                ("c\"d", false),
                ("grep", true),
                ("x y", false),
                ("cd", true),
            ]
        );
        assert!(!expect);
        let (w, _, _) = words(&"echo 'unterminated".chars().collect::<Vec<_>>());
        assert_eq!(w[1].open, Some('\''));
        assert_eq!(w[1].text, "unterminated");
    }

    fn ctx<'a>(cwd: &Path, history: &'a History, path_var: Option<OsString>) -> Context<'a> {
        Context {
            cwd: Some(cwd.to_owned()),
            home: cwd.to_owned(),
            path_var,
            history,
            limit: 50,
        }
    }

    fn texts(items: &[Completion]) -> Vec<&str> {
        items.iter().map(|c| c.text.as_str()).collect()
    }

    #[test]
    fn paths_dirs_hidden_and_quoting() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        std::fs::create_dir(d.join("src")).unwrap();
        std::fs::write(d.join("src/main.rs"), "").unwrap();
        std::fs::write(d.join("my file.txt"), "").unwrap();
        std::fs::write(d.join(".env"), "").unwrap();
        let state = tempfile::tempdir().unwrap();
        let history = History::open(
            state.path(),
            super::super::history::HistoryConfig {
                import: false,
                ..Default::default()
            },
            state.path(),
        );
        let caches = Caches::default();
        let c = ctx(d, &history, None);

        let items = complete(&c, &caches, "cat ", 4);
        assert_eq!(texts(&items), vec!["src/", r"my\ file.txt"]);
        assert_eq!(items[0].kind, CompletionKind::Dir);
        assert_eq!((items[0].start, items[0].end), (4, 4));

        let items = complete(&c, &caches, "cat .", 5);
        assert_eq!(texts(&items), vec![".env"]);

        let items = complete(&c, &caches, "vim src/m", 9);
        assert_eq!(texts(&items), vec!["src/main.rs"]);
        assert_eq!((items[0].start, items[0].end), (4, 9));

        let items = complete(&c, &caches, "cat 'my", 7);
        assert_eq!(texts(&items), vec!["'my file.txt"]);

        // Case-insensitive fallback.
        let items = complete(&c, &caches, "cd SR", 5);
        assert_eq!(texts(&items), vec!["src/"]);
    }

    #[test]
    fn history_and_path_commands() {
        let dir = tempfile::tempdir().unwrap();
        let bin = dir.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        for name in ["frobnicate", "frobulate", "other"] {
            let p = bin.join(name);
            std::fs::write(&p, "#!/bin/sh\n").unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::fs::write(bin.join("not-exec"), "").unwrap();
        let state = tempfile::tempdir().unwrap();
        let history = History::open(
            state.path(),
            super::super::history::HistoryConfig {
                import: false,
                ..Default::default()
            },
            state.path(),
        );
        history.record("frobnicate --all", false, Some("/x"), Some(0), 1);
        let caches = Caches::default();
        let c = ctx(dir.path(), &history, Some(bin.clone().into_os_string()));
        let items = complete(&c, &caches, "frob", 4);
        assert_eq!(
            texts(&items),
            vec!["frobnicate --all", "frobnicate", "frobulate"]
        );
        assert_eq!(items[0].kind, CompletionKind::History);
        assert_eq!(items[1].kind, CompletionKind::Command);
        // Mid-line: no history.
        let items = complete(&c, &caches, "frob | cat", 4);
        assert_eq!(texts(&items), vec!["frobnicate", "frobulate"]);
        assert_eq!((items[0].start, items[0].end), (0, 4));
    }
}
