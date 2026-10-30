//! Git through the `git` CLI (no libgit2): status from `--porcelain=v2 -z`, diffs between
//! trees with rename detection, and worktree snapshots as tree objects.
//!
//! A *worktree tree* is the working directory as git would commit it after `git add -A`
//! (tracked changes and untracked, non-ignored files), written with a throwaway copy of the
//! index (`GIT_INDEX_FILE`), so the user's index and stash are never touched — the same idea
//! as `git stash create`, which cannot include untracked files. Every diff is a diff between
//! two trees, which makes "HEAD vs worktree" include new files and makes an agent turn's
//! changes (start tree vs end tree) one more case of the same code.
//!
//! Everything here blocks; callers run it on `spawn_blocking`.

use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use proto::{
    DiffBase, DiffLine, FileChange, FileDiff, GitDiff, GitDiffRequest, GitFileStatus, GitStatus,
    Hunk, LineKind, WsError,
};

/// A file's patch larger than this keeps its counts but loses its hunks.
const MAX_FILE_PATCH: usize = 1 << 20;
/// Hunks stop being collected once the whole patch is this large.
const MAX_TOTAL_PATCH: usize = 8 << 20;

/// Runs git in `dir` and returns stdout.
pub(crate) fn git(dir: &Path, args: &[&str]) -> Result<Vec<u8>, WsError> {
    git_env(dir, args, &[])
}

/// Settings that keep a repository's own config from running programs when the daemon looks
/// at it: a `.git` directory can come from anywhere (an unpacked archive), and its config
/// may name an fsmonitor, hooks or automatic maintenance that would run as the user.
const SAFE_CONFIG: &[&str] = &[
    "core.fsmonitor=false",
    "gc.auto=0",
    "maintenance.auto=false",
    "core.pager=cat",
    "core.editor=true",
];

/// Subcommands the person asked for that keep the repository's hooks (`pre-push`).
const HOOKED: &[&str] = &["push"];

fn command(dir: &Path, args: &[&str], env: &[(&str, &Path)]) -> Command {
    let mut cmd = Command::new("git");
    cmd.current_dir(dir)
        .args(["-c", "core.quotePath=false", "-c", "color.ui=false"]);
    for setting in SAFE_CONFIG {
        cmd.args(["-c", setting]);
    }
    if !args.first().is_some_and(|a| HOOKED.contains(a)) {
        cmd.args(["-c", "core.hooksPath=/dev/null"]);
    }
    for setting in neutralised_filters(dir) {
        cmd.arg("-c").arg(setting);
    }
    cmd.args(args)
        // Status must not take the index lock behind the user's back.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null());
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd
}

/// Git LFS's own filter commands, as `git lfs install --local` writes them.
const LFS_FILTERS: &[&str] = &[
    "git-lfs clean -- %f",
    "git-lfs smudge -- %f",
    "git-lfs filter-process",
];

/// `-c` overrides emptying the clean/smudge/process filters the repository's own config
/// defines (status and diff run them on changed files), Git LFS's excepted. Filters in the
/// user's global config are theirs and stay.
fn neutralised_filters(dir: &Path) -> Vec<String> {
    let Ok(out) = Command::new("git")
        .current_dir(dir)
        .args(["config", "--local", "--null", "--get-regexp"])
        .arg(r"^filter\..*\.(clean|smudge|process)$")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    else {
        return Vec::new();
    };
    overrides_for(&out.stdout)
}

/// The overrides for `git config --null --get-regexp` output (`key\nvalue\0`…).
fn overrides_for(listing: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    for entry in listing.split(|&b| b == 0).filter(|e| !e.is_empty()) {
        let entry = String::from_utf8_lossy(entry);
        let (key, value) = entry.split_once('\n').unwrap_or((&entry, ""));
        if !LFS_FILTERS.contains(&value.trim()) {
            out.push(format!("{key}="));
            if let Some(name) = key.rsplit_once('.').map(|(name, _)| name) {
                out.push(format!("{name}.required=false"));
            }
        }
    }
    out.dedup();
    out
}

fn git_env(dir: &Path, args: &[&str], env: &[(&str, &Path)]) -> Result<Vec<u8>, WsError> {
    let out = command(dir, args, env).output().map_err(spawn_error)?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        Err(git_failed(args, &out.stderr))
    }
}

fn spawn_error(e: std::io::Error) -> WsError {
    if e.kind() == std::io::ErrorKind::NotFound {
        WsError::Unavailable("git is not installed on the host".into())
    } else {
        WsError::Failed(format!("running git: {e}"))
    }
}

fn git_failed(args: &[&str], stderr: &[u8]) -> WsError {
    let msg = String::from_utf8_lossy(stderr).trim().to_owned();
    if msg.contains("not a git repository") {
        WsError::NotFound(msg)
    } else {
        WsError::Failed(format!(
            "git {}: {msg}",
            args.first().copied().unwrap_or_default()
        ))
    }
}

fn text(out: Vec<u8>) -> String {
    String::from_utf8_lossy(&out).trim_end().to_owned()
}

/// The top level of the worktree containing `dir`.
pub(crate) fn toplevel(dir: &Path) -> Result<PathBuf, WsError> {
    let dir = if dir.is_dir() {
        dir
    } else {
        dir.parent().unwrap_or(dir)
    };
    Ok(PathBuf::from(text(git(
        dir,
        &["rev-parse", "--show-toplevel"],
    )?)))
}

/// Rejects revisions that could be read as options.
fn check_rev(rev: &str) -> Result<(), WsError> {
    if rev.is_empty() || rev.starts_with('-') || rev.contains(char::is_whitespace) {
        Err(WsError::Invalid(format!("bad revision {rev:?}")))
    } else {
        Ok(())
    }
}

// --- status ---------------------------------------------------------------------------------

pub(crate) fn status(dir: &Path) -> Result<GitStatus, WsError> {
    let root = toplevel(dir)?;
    let out = git(
        &root,
        &[
            "status",
            "--porcelain=v2",
            "--branch",
            "-z",
            "--untracked-files=normal",
        ],
    )?;
    Ok(parse_status(&root, &out))
}

fn change_of(c: u8) -> FileChange {
    match c {
        b'M' => FileChange::Modified,
        b'A' => FileChange::Added,
        b'D' => FileChange::Deleted,
        b'R' => FileChange::Renamed,
        b'C' => FileChange::Copied,
        b'T' => FileChange::TypeChanged,
        b'U' => FileChange::Unmerged,
        _ => FileChange::Unmodified,
    }
}

fn parse_status(root: &Path, out: &[u8]) -> GitStatus {
    let mut status = GitStatus {
        root: root.to_string_lossy().into_owned(),
        branch: None,
        head: None,
        upstream: None,
        ahead: 0,
        behind: 0,
        files: Vec::new(),
    };
    let mut fields = out.split(|&b| b == 0).map(|f| String::from_utf8_lossy(f));
    while let Some(entry) = fields.next() {
        if let Some(header) = entry.strip_prefix("# ") {
            let (key, value) = header.split_once(' ').unwrap_or((header, ""));
            match key {
                "branch.oid" if value != "(initial)" => status.head = Some(value.to_owned()),
                "branch.head" if value != "(detached)" => status.branch = Some(value.to_owned()),
                "branch.upstream" => status.upstream = Some(value.to_owned()),
                "branch.ab" => {
                    for part in value.split(' ') {
                        if let Some(n) = part.strip_prefix('+') {
                            status.ahead = n.parse().unwrap_or(0);
                        } else if let Some(n) = part.strip_prefix('-') {
                            status.behind = n.parse().unwrap_or(0);
                        }
                    }
                }
                _ => {}
            }
            continue;
        }
        let mut parts = entry.splitn(2, ' ');
        let kind = parts.next().unwrap_or_default();
        let rest = parts.next().unwrap_or_default();
        // Fields before the path: 1 → 7, 2 → 8 (plus score), u → 9.
        let skip = match kind {
            "1" => 7,
            "2" => 8,
            "u" => 9,
            "?" => {
                status.files.push(GitFileStatus {
                    path: rest.to_owned(),
                    orig_path: None,
                    staged: FileChange::Untracked,
                    unstaged: FileChange::Untracked,
                });
                continue;
            }
            _ => continue,
        };
        let mut cols = rest.splitn(skip + 1, ' ');
        let xy = cols.next().unwrap_or("..").as_bytes().to_vec();
        let path = cols.nth(skip - 1).unwrap_or_default().to_owned();
        let orig_path = (kind == "2").then(|| fields.next().unwrap_or_default().into_owned());
        let (staged, unstaged) = if kind == "u" {
            (FileChange::Unmerged, FileChange::Unmerged)
        } else {
            (
                change_of(*xy.first().unwrap_or(&b'.')),
                change_of(*xy.get(1).unwrap_or(&b'.')),
            )
        };
        status.files.push(GitFileStatus {
            path,
            orig_path,
            staged,
            unstaged,
        });
    }
    status
}

// --- trees ----------------------------------------------------------------------------------

/// The tree of an empty directory (object format aware).
fn empty_tree(root: &Path) -> Result<String, WsError> {
    let out = command(root, &["hash-object", "-t", "tree", "--stdin"], &[])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(spawn_error)?
        .wait_with_output()
        .map_err(|e| WsError::Failed(e.to_string()))?;
    Ok(text(out.stdout))
}

fn head_tree(root: &Path) -> Result<String, WsError> {
    match git(root, &["rev-parse", "--verify", "-q", "HEAD^{tree}"]) {
        Ok(out) => Ok(text(out)),
        // No commits yet.
        Err(_) => empty_tree(root),
    }
}

fn rev_tree(root: &Path, rev: &str) -> Result<String, WsError> {
    check_rev(rev)?;
    git(root, &["rev-parse", "--verify", &format!("{rev}^{{tree}}")])
        .map(text)
        .map_err(|_| WsError::NotFound(format!("revision {rev}")))
}

/// A copy of the repository's index in a temporary file, removed on drop.
struct TempIndex(PathBuf);

impl TempIndex {
    fn new(root: &Path) -> Result<Self, WsError> {
        let index = PathBuf::from(text(git(root, &["rev-parse", "--git-path", "index"])?));
        let index = if index.is_absolute() {
            index
        } else {
            root.join(index)
        };
        // In a private directory: the index lists the repository's paths and hashes.
        let dir = crate::fsutil::create_private_temp_dir(&format!("{}-index", brand::DIR_NAME))
            .map_err(|e| WsError::Failed(e.to_string()))?;
        let tmp = Self(dir.join("index"));
        // Starting from the real index keeps its stat cache, so unchanged files are not
        // re-hashed.
        if index.exists() {
            std::fs::copy(&index, &tmp.0).map_err(|e| WsError::Failed(e.to_string()))?;
        }
        Ok(tmp)
    }
}

impl Drop for TempIndex {
    fn drop(&mut self) {
        if let Some(dir) = self.0.parent() {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

/// The index as a tree.
fn index_tree(root: &Path) -> Result<String, WsError> {
    let tmp = TempIndex::new(root)?;
    git_env(root, &["write-tree"], &[("GIT_INDEX_FILE", &tmp.0)])
        .map(text)
        .map_err(|e| match e {
            WsError::Failed(m) if m.contains("unmerged") => {
                WsError::Conflict("the index has unmerged paths".into())
            }
            e => e,
        })
}

/// The working directory as a tree (tracked changes plus untracked, non-ignored files).
/// Writes blobs into the object database; the user's index is untouched.
pub(crate) fn worktree_tree(root: &Path) -> Result<String, WsError> {
    let tmp = TempIndex::new(root)?;
    let env = [("GIT_INDEX_FILE", tmp.0.as_path())];
    git_env(root, &["add", "-A", "--", "."], &env)?;
    git_env(root, &["write-tree"], &env).map(text)
}

// --- diffs ----------------------------------------------------------------------------------

pub(crate) fn diff(req: &GitDiffRequest, dir: &Path) -> Result<GitDiff, WsError> {
    let root = toplevel(dir)?;
    let (from, to) = match &req.base {
        DiffBase::Head => (head_tree(&root)?, worktree_tree(&root)?),
        DiffBase::Index => (index_tree(&root)?, worktree_tree(&root)?),
        DiffBase::Staged => (head_tree(&root)?, index_tree(&root)?),
        DiffBase::Rev(rev) => (rev_tree(&root, rev)?, worktree_tree(&root)?),
        DiffBase::MergeBase(branch) => {
            check_rev(branch)?;
            let base = git(&root, &["merge-base", "HEAD", branch])
                .map(text)
                .map_err(|_| WsError::NotFound(format!("merge base with {branch}")))?;
            (rev_tree(&root, &base)?, worktree_tree(&root)?)
        }
    };
    diff_trees(&root, &from, &to, &req.files, req.context, req.hunks)
}

/// Diff between two trees, file by file.
pub(crate) fn diff_trees(
    root: &Path,
    from: &str,
    to: &str,
    files: &[String],
    context: u32,
    hunks: bool,
) -> Result<GitDiff, WsError> {
    check_rev(from)?;
    check_rev(to)?;
    let with_files = |mut args: Vec<String>| {
        args.push("--".into());
        args.extend(files.iter().cloned());
        args
    };
    let base = |extra: &[&str]| {
        let mut v: Vec<String> = ["diff-tree", "-r", "-M", "--no-commit-id"]
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
        v.extend(extra.iter().map(|s| (*s).to_owned()));
        v.push(from.to_owned());
        v.push(to.to_owned());
        with_files(v)
    };
    fn as_refs(v: &[String]) -> Vec<&str> {
        v.iter().map(String::as_str).collect()
    }
    let raw = git(root, &as_refs(&base(&["-z", "--raw"])))?;
    let numstat = git(root, &as_refs(&base(&["-z", "--numstat"])))?;
    let mut out = parse_raw(&raw);
    for (file, (add, del)) in out.iter_mut().zip(parse_numstat(&numstat)) {
        match (add, del) {
            (Some(a), Some(d)) => {
                file.additions = a;
                file.deletions = d;
            }
            _ => file.binary = true,
        }
    }
    let mut truncated = false;
    if hunks {
        let unified = format!("-U{}", context.min(10_000));
        let args = base(&[
            "-p",
            "--no-ext-diff",
            "--no-textconv",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            &unified,
        ]);
        truncated = attach_hunks(root, &as_refs(&args), &mut out)?;
    } else {
        for f in &mut out {
            f.hunks_omitted = !f.binary;
        }
    }
    Ok(GitDiff {
        root: root.to_string_lossy().into_owned(),
        from: from.to_owned(),
        to: to.to_owned(),
        files: out,
        truncated,
    })
}

/// `:old_mode new_mode old_oid new_oid STATUS\0path\0[path2\0]`.
fn parse_raw(raw: &[u8]) -> Vec<FileDiff> {
    let mut fields = raw.split(|&b| b == 0);
    let mut files = Vec::new();
    while let Some(meta) = fields.next() {
        let Some(meta) = meta.strip_prefix(b":") else {
            continue;
        };
        let meta = String::from_utf8_lossy(meta);
        let status = meta.split(' ').nth(4).unwrap_or("M");
        let code = status.as_bytes().first().copied().unwrap_or(b'M');
        let first = fields
            .next()
            .map(|p| String::from_utf8_lossy(p).into_owned());
        let (path, old_path) = if matches!(code, b'R' | b'C') {
            let second = fields
                .next()
                .map(|p| String::from_utf8_lossy(p).into_owned());
            (second.unwrap_or_default(), first)
        } else {
            (first.unwrap_or_default(), None)
        };
        files.push(FileDiff {
            path,
            old_path,
            change: change_of(code),
            binary: false,
            additions: 0,
            deletions: 0,
            hunks: Vec::new(),
            hunks_omitted: false,
        });
    }
    files
}

/// `added\tdeleted\tpath\0` or, for renames, `added\tdeleted\t\0old\0new\0`; `-` for binary.
fn parse_numstat(out: &[u8]) -> Vec<(Option<u32>, Option<u32>)> {
    let mut fields = out.split(|&b| b == 0);
    let mut counts = Vec::new();
    while let Some(entry) = fields.next() {
        if entry.is_empty() {
            continue;
        }
        let entry = String::from_utf8_lossy(entry);
        let mut cols = entry.splitn(3, '\t');
        let add = cols.next().and_then(|n| n.parse().ok());
        let del = cols.next().and_then(|n| n.parse().ok());
        if cols.next().unwrap_or_default().is_empty() {
            // A rename: the two paths follow as separate fields.
            fields.next();
            fields.next();
        }
        counts.push((add, del));
    }
    counts
}

/// Streams `git diff-tree -p` and fills each file's hunks in order. Returns whether any were
/// left out for size.
fn attach_hunks(root: &Path, args: &[&str], files: &mut [FileDiff]) -> Result<bool, WsError> {
    let mut child = command(root, args, &[])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(spawn_error)?;
    let stdout = child.stdout.take().expect("piped");
    let mut reader = BufReader::with_capacity(64 << 10, stdout);
    let mut index: Option<usize> = None;
    let mut file_bytes = 0usize;
    let mut total = 0usize;
    let mut truncated = false;
    let mut line = Vec::new();
    loop {
        line.clear();
        let n = reader
            .read_until(b'\n', &mut line)
            .map_err(|e| WsError::Failed(e.to_string()))?;
        if n == 0 {
            break;
        }
        total += n;
        if line.starts_with(b"diff --git ") {
            index = Some(index.map_or(0, |i| i + 1));
            file_bytes = 0;
            if total > MAX_TOTAL_PATCH {
                truncated = true;
                break;
            }
            continue;
        }
        let Some(file) = index.and_then(|i| files.get_mut(i)) else {
            continue;
        };
        file_bytes += n;
        if file.hunks_omitted {
            continue;
        }
        if file_bytes > MAX_FILE_PATCH {
            file.hunks.clear();
            file.hunks_omitted = true;
            truncated = true;
            continue;
        }
        let body = line.strip_suffix(b"\n").unwrap_or(&line);
        if body.starts_with(b"Binary files ") || body.starts_with(b"GIT binary patch") {
            file.binary = true;
            continue;
        }
        if let Some(h) = parse_hunk_header(body) {
            file.hunks.push(h);
            continue;
        }
        let Some(hunk) = file.hunks.last_mut() else {
            // Extended header lines (index, mode, similarity, ---/+++).
            continue;
        };
        let (kind, rest) = match body.first() {
            Some(b' ') => (LineKind::Context, &body[1..]),
            Some(b'+') => (LineKind::Added, &body[1..]),
            Some(b'-') => (LineKind::Removed, &body[1..]),
            Some(b'\\') => (LineKind::NoNewline, &body[..0]),
            // An empty context line (some tools strip the space).
            None => (LineKind::Context, body),
            Some(_) => continue,
        };
        let rest = rest.strip_suffix(b"\r").unwrap_or(rest);
        hunk.lines.push(DiffLine {
            kind,
            text: String::from_utf8_lossy(rest).into_owned(),
        });
    }
    if truncated {
        let _ = child.kill();
        let start = index.unwrap_or(0);
        for f in files.iter_mut().skip(start) {
            if !f.binary {
                f.hunks.clear();
                f.hunks_omitted = true;
            }
        }
    } else {
        // Drain anything left so git exits cleanly.
        let _ = std::io::copy(&mut reader.by_ref().take(u64::MAX), &mut std::io::sink());
    }
    let _ = child.wait();
    Ok(truncated)
}

/// `@@ -a[,b] +c[,d] @@ header`.
fn parse_hunk_header(line: &[u8]) -> Option<Hunk> {
    let line = std::str::from_utf8(line.strip_prefix(b"@@ -")?).ok()?;
    let (ranges, header) = line.split_once(" @@")?;
    let (old, new) = ranges.split_once(" +")?;
    let range = |r: &str| -> Option<(u32, u32)> {
        match r.split_once(',') {
            Some((s, n)) => Some((s.parse().ok()?, n.parse().ok()?)),
            None => Some((r.parse().ok()?, 1)),
        }
    };
    let (old_start, old_lines) = range(old)?;
    let (new_start, new_lines) = range(new)?;
    Some(Hunk {
        old_start,
        old_lines,
        new_start,
        new_lines,
        header: header.trim_start().to_owned(),
        lines: Vec::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `.git` from an unpacked archive whose config runs programs: looking at it (status,
    /// a worktree snapshot) must run none of them.
    #[test]
    fn a_repositorys_own_config_runs_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        let marker = dir.path().join("ran");
        let run = |args: &[&str]| {
            let ok = Command::new("git")
                .current_dir(&repo)
                .args(args)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?}");
        };
        std::fs::create_dir(&repo).unwrap();
        run(&["init", "-q"]);
        run(&["config", "user.email", "t@t"]);
        run(&["config", "user.name", "t"]);
        std::fs::write(repo.join("a.txt"), "one\n").unwrap();
        run(&["add", "a.txt"]);
        run(&["commit", "-qm", "one"]);
        let script = dir.path().join("evil.sh");
        std::fs::write(
            &script,
            format!("#!/bin/sh\necho \"$0 $*\" >> '{}'\ncat\n", marker.display()),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let evil = script.to_string_lossy().into_owned();
        run(&["config", "core.fsmonitor", &evil]);
        run(&["config", "filter.x.clean", &evil]);
        run(&["config", "filter.x.smudge", &evil]);
        run(&["config", "filter.x.required", "true"]);
        let hooks = repo.join(".git/hooks");
        for hook in [
            "post-index-change",
            "reference-transaction",
            "post-checkout",
        ] {
            std::fs::copy(&script, hooks.join(hook)).unwrap();
        }
        std::fs::write(repo.join(".gitattributes"), "* filter=x\n").unwrap();
        std::fs::write(repo.join("a.txt"), "two\n").unwrap();
        std::fs::write(repo.join("b.txt"), "new\n").unwrap();

        let s = status(&repo).unwrap();
        assert!(!s.files.is_empty());
        let _ = worktree_tree(&repo);
        assert!(
            !marker.exists(),
            "ran: {}",
            std::fs::read_to_string(&marker).unwrap_or_default()
        );
    }

    #[test]
    fn lfs_filters_stay_and_others_are_emptied() {
        let listing = b"filter.lfs.clean\ngit-lfs clean -- %f\0filter.lfs.process\ngit-lfs filter-process\0filter.x.smudge\nsh -c evil\0";
        assert_eq!(
            overrides_for(listing),
            ["filter.x.smudge=", "filter.x.required=false"]
        );
    }

    #[test]
    fn parses_porcelain_v2() {
        let out = b"# branch.oid 1234\0# branch.head main\0# branch.upstream origin/main\0\
# branch.ab +2 -1\0\
1 .M N... 100644 100644 100644 aaa aaa src/a b.rs\0\
2 R. N... 100644 100644 100644 bbb bbb R100 new.rs\0old.rs\0\
u UU N... 100644 100644 100644 100644 c1 c2 c3 conflict.txt\0\
? untracked.txt\0";
        let s = parse_status(Path::new("/r"), out);
        assert_eq!(s.branch.as_deref(), Some("main"));
        assert_eq!(s.head.as_deref(), Some("1234"));
        assert_eq!((s.ahead, s.behind), (2, 1));
        assert_eq!(s.files.len(), 4);
        assert_eq!(s.files[0].path, "src/a b.rs");
        assert_eq!(s.files[0].unstaged, FileChange::Modified);
        assert_eq!(s.files[0].staged, FileChange::Unmodified);
        assert_eq!(s.files[1].path, "new.rs");
        assert_eq!(s.files[1].orig_path.as_deref(), Some("old.rs"));
        assert_eq!(s.files[1].staged, FileChange::Renamed);
        assert_eq!(s.files[2].staged, FileChange::Unmerged);
        assert_eq!(s.files[3].unstaged, FileChange::Untracked);
    }

    #[test]
    fn parses_hunk_headers() {
        let h = parse_hunk_header(b"@@ -1,3 +1 @@ fn main()").unwrap();
        assert_eq!(
            (h.old_start, h.old_lines, h.new_start, h.new_lines),
            (1, 3, 1, 1)
        );
        assert_eq!(h.header, "fn main()");
    }
}
