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

/// Returns stdout.
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

/// The config every daemon-run git in `dir` gets (`key=value`), and so does the git `gh`
/// runs there.
pub(crate) fn guard(dir: &Path, hooks: bool) -> Vec<String> {
    let mut settings: Vec<String> = SAFE_CONFIG
        .iter()
        .map(|setting| (*setting).to_owned())
        .collect();
    if !hooks {
        settings.push("core.hooksPath=/dev/null".into());
    }
    settings.extend(neutralised_filters(dir));
    settings
}

fn command(dir: &Path, args: &[&str], env: &[(&str, &Path)]) -> Command {
    let mut command = Command::new("git");
    command
        .current_dir(dir)
        .args(["-c", "core.quotePath=false", "-c", "color.ui=false"]);
    let hooks = args
        .first()
        .is_some_and(|subcommand| HOOKED.contains(subcommand));
    for setting in guard(dir, hooks) {
        command.arg("-c").arg(setting);
    }
    command.args(args.first());
    // Status and diff look into a submodule's files by running `git status` inside it, under
    // that repository's own filters, which the overrides above do not name.
    if matches!(args.first(), Some(&("status" | "diff"))) {
        command.arg("--ignore-submodules=dirty");
    }
    command
        .args(args.iter().skip(1))
        // Status must not take the index lock behind the user's back.
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null());
    for (name, value) in env {
        command.env(name, value);
    }
    command
}

/// Git LFS's own filter commands, as `git lfs install --local` writes them.
const LFS_FILTERS: &[&str] = &[
    "git-lfs clean -- %f",
    "git-lfs smudge -- %f",
    "git-lfs filter-process",
];

/// `-c` overrides emptying the clean/smudge/process filters the repository defines (status
/// and diff run them on changed files), Git LFS's excepted: in `.git/config`, the files it
/// includes, and the worktree's config. Filters in the user's global or system config are
/// theirs and stay.
fn neutralised_filters(dir: &Path) -> Vec<String> {
    let Ok(output) = Command::new("git")
        .current_dir(dir)
        .args(["config", "--show-scope", "--null", "--get-regexp"])
        .arg(r"^filter\..*\.(clean|smudge|process)$")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    else {
        return Vec::new();
    };
    overrides_for(&output.stdout)
}

/// The overrides for `git config --show-scope --null --get-regexp` output
/// (`scope\0key\nvalue\0`…).
fn overrides_for(listing: &[u8]) -> Vec<String> {
    let mut overrides = Vec::new();
    let mut fields = listing.split(|&byte| byte == 0);
    while let (Some(scope), Some(entry)) = (fields.next(), fields.next()) {
        if matches!(scope, b"global" | b"system") {
            continue;
        }
        let entry = String::from_utf8_lossy(entry);
        let (key, value) = entry.split_once('\n').unwrap_or((&entry, ""));
        if !LFS_FILTERS.contains(&value.trim()) {
            overrides.push(format!("{key}="));
            if let Some(name) = key.rsplit_once('.').map(|(name, _)| name) {
                overrides.push(format!("{name}.required=false"));
            }
        }
    }
    overrides.dedup();
    overrides
}

fn git_env(dir: &Path, args: &[&str], env: &[(&str, &Path)]) -> Result<Vec<u8>, WsError> {
    let output = command(dir, args, env).output().map_err(spawn_error)?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err(git_failed(args, &output.stderr))
    }
}

fn spawn_error(error: std::io::Error) -> WsError {
    if error.kind() == std::io::ErrorKind::NotFound {
        WsError::Unavailable("git is not installed on the host".into())
    } else {
        WsError::Failed(format!("running git: {error}"))
    }
}

fn git_failed(args: &[&str], stderr: &[u8]) -> WsError {
    let message = String::from_utf8_lossy(stderr).trim().to_owned();
    if message.contains("not a git repository") {
        WsError::NotFound(message)
    } else {
        WsError::Failed(format!(
            "git {}: {message}",
            args.first().copied().unwrap_or_default()
        ))
    }
}

fn text(stdout: Vec<u8>) -> String {
    String::from_utf8_lossy(&stdout).trim_end().to_owned()
}

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

pub(crate) fn status(dir: &Path) -> Result<GitStatus, WsError> {
    let root = toplevel(dir)?;
    let porcelain = git(
        &root,
        &[
            "status",
            "--porcelain=v2",
            "--branch",
            "-z",
            "--untracked-files=normal",
        ],
    )?;
    Ok(parse_status(&root, &porcelain))
}

fn change_of(code: u8) -> FileChange {
    match code {
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

fn parse_status(root: &Path, porcelain: &[u8]) -> GitStatus {
    let mut status = GitStatus {
        root: root.to_string_lossy().into_owned(),
        branch: None,
        head: None,
        upstream: None,
        ahead: 0,
        behind: 0,
        files: Vec::new(),
    };
    let mut fields = porcelain
        .split(|&byte| byte == 0)
        .map(|field| String::from_utf8_lossy(field));
    while let Some(entry) = fields.next() {
        if let Some(header) = entry.strip_prefix("# ") {
            let (key, value) = header.split_once(' ').unwrap_or((header, ""));
            match key {
                "branch.oid" if value != "(initial)" => status.head = Some(value.to_owned()),
                "branch.head" if value != "(detached)" => status.branch = Some(value.to_owned()),
                "branch.upstream" => status.upstream = Some(value.to_owned()),
                "branch.ab" => {
                    for part in value.split(' ') {
                        if let Some(count) = part.strip_prefix('+') {
                            status.ahead = count.parse().unwrap_or(0);
                        } else if let Some(count) = part.strip_prefix('-') {
                            status.behind = count.parse().unwrap_or(0);
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
        let mut columns = rest.splitn(skip + 1, ' ');
        let xy = columns.next().unwrap_or("..").as_bytes().to_vec();
        let path = columns.nth(skip - 1).unwrap_or_default().to_owned();
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

/// Hashed rather than hard-coded so it matches the repository's object format.
fn empty_tree(root: &Path) -> Result<String, WsError> {
    let output = command(root, &["hash-object", "-t", "tree", "--stdin"], &[])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(spawn_error)?
        .wait_with_output()
        .map_err(|error| WsError::Failed(error.to_string()))?;
    Ok(text(output.stdout))
}

fn head_tree(root: &Path) -> Result<String, WsError> {
    match git(root, &["rev-parse", "--verify", "-q", "HEAD^{tree}"]) {
        Ok(stdout) => Ok(text(stdout)),
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
            .map_err(|error| WsError::Failed(error.to_string()))?;
        let copy = Self(dir.join("index"));
        // Starting from the real index keeps its stat cache, so unchanged files are not
        // re-hashed.
        if index.exists() {
            std::fs::copy(&index, &copy.0).map_err(|error| WsError::Failed(error.to_string()))?;
        }
        Ok(copy)
    }
}

impl Drop for TempIndex {
    fn drop(&mut self) {
        if let Some(dir) = self.0.parent() {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

fn index_tree(root: &Path) -> Result<String, WsError> {
    let index = TempIndex::new(root)?;
    git_env(root, &["write-tree"], &[("GIT_INDEX_FILE", &index.0)])
        .map(text)
        .map_err(|error| match error {
            WsError::Failed(message) if message.contains("unmerged") => {
                WsError::Conflict("the index has unmerged paths".into())
            }
            error => error,
        })
}

/// The working directory as a tree (tracked changes plus untracked, non-ignored files).
/// Writes blobs into the object database; the user's index is untouched.
pub(crate) fn worktree_tree(root: &Path) -> Result<String, WsError> {
    let index = TempIndex::new(root)?;
    let env = [("GIT_INDEX_FILE", index.0.as_path())];
    // `add` looks for changes inside a submodule by running `git status` in it, under that
    // repository's own filters. Submodules are recorded at their HEAD instead, as `add` would.
    let gitlinks = gitlinks(&git_env(root, &["ls-files", "--stage", "-z"], &env)?);
    let mut add = vec!["add".to_owned(), "-A".into(), "--".into(), ".".into()];
    add.extend(
        gitlinks
            .iter()
            .map(|path| format!(":(exclude,literal){path}")),
    );
    git_env(
        root,
        &add.iter().map(String::as_str).collect::<Vec<_>>(),
        &env,
    )?;
    for path in &gitlinks {
        let dir = root.join(path);
        if !dir.exists() {
            git_env(root, &["update-index", "--force-remove", "--", path], &env)?;
        } else if dir.join(".git").exists()
            && let Ok(head) = git(&dir, &["rev-parse", "--verify", "-q", "HEAD"])
        {
            let info = format!("160000,{},{path}", text(head));
            git_env(root, &["update-index", "--cacheinfo", &info], &env)?;
        }
    }
    git_env(root, &["write-tree"], &env).map(text)
}

/// The submodule paths in `git ls-files --stage -z` output.
fn gitlinks(listing: &[u8]) -> Vec<String> {
    listing
        .split(|&byte| byte == 0)
        .filter_map(|record| {
            let (mode_and_oid, path) =
                record.split_at(record.iter().position(|&byte| byte == b'\t')?);
            mode_and_oid
                .starts_with(b"160000 ")
                .then(|| String::from_utf8_lossy(&path[1..]).into_owned())
        })
        .collect()
}

pub(crate) fn diff(request: &GitDiffRequest, dir: &Path) -> Result<GitDiff, WsError> {
    let root = toplevel(dir)?;
    let (from, to) = match &request.base {
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
    diff_trees(
        &root,
        &from,
        &to,
        &request.files,
        request.context,
        request.hunks,
    )
}

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
        let mut args: Vec<String> = ["diff-tree", "-r", "-M", "--no-commit-id"]
            .iter()
            .map(|arg| (*arg).to_owned())
            .collect();
        args.extend(extra.iter().map(|arg| (*arg).to_owned()));
        args.push(from.to_owned());
        args.push(to.to_owned());
        with_files(args)
    };
    fn as_refs(args: &[String]) -> Vec<&str> {
        args.iter().map(String::as_str).collect()
    }
    let raw = git(root, &as_refs(&base(&["-z", "--raw"])))?;
    let numstat = git(root, &as_refs(&base(&["-z", "--numstat"])))?;
    let mut file_diffs = parse_raw(&raw);
    for (file, counts) in file_diffs.iter_mut().zip(parse_numstat(&numstat)) {
        match counts {
            (Some(additions), Some(deletions)) => {
                file.additions = additions;
                file.deletions = deletions;
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
        truncated = attach_hunks(root, &as_refs(&args), &mut file_diffs)?;
    } else {
        for file in &mut file_diffs {
            file.hunks_omitted = !file.binary;
        }
    }
    Ok(GitDiff {
        root: root.to_string_lossy().into_owned(),
        from: from.to_owned(),
        to: to.to_owned(),
        files: file_diffs,
        truncated,
    })
}

/// `:old_mode new_mode old_oid new_oid STATUS\0path\0[path2\0]`.
fn parse_raw(raw: &[u8]) -> Vec<FileDiff> {
    let mut fields = raw.split(|&byte| byte == 0);
    let mut files = Vec::new();
    while let Some(header) = fields.next() {
        let Some(header) = header.strip_prefix(b":") else {
            continue;
        };
        let header = String::from_utf8_lossy(header);
        let status = header.split(' ').nth(4).unwrap_or("M");
        let code = status.as_bytes().first().copied().unwrap_or(b'M');
        let first = fields
            .next()
            .map(|path| String::from_utf8_lossy(path).into_owned());
        let (path, old_path) = if matches!(code, b'R' | b'C') {
            let second = fields
                .next()
                .map(|path| String::from_utf8_lossy(path).into_owned());
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
fn parse_numstat(numstat: &[u8]) -> Vec<(Option<u32>, Option<u32>)> {
    let mut fields = numstat.split(|&byte| byte == 0);
    let mut counts = Vec::new();
    while let Some(entry) = fields.next() {
        if entry.is_empty() {
            continue;
        }
        let entry = String::from_utf8_lossy(entry);
        let mut columns = entry.splitn(3, '\t');
        let additions = columns.next().and_then(|count| count.parse().ok());
        let deletions = columns.next().and_then(|count| count.parse().ok());
        if columns.next().unwrap_or_default().is_empty() {
            // A rename: the two paths follow as separate fields.
            fields.next();
            fields.next();
        }
        counts.push((additions, deletions));
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
        let read = reader
            .read_until(b'\n', &mut line)
            .map_err(|error| WsError::Failed(error.to_string()))?;
        if read == 0 {
            break;
        }
        total += read;
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
        file_bytes += read;
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
        if let Some(hunk) = parse_hunk_header(body) {
            file.hunks.push(hunk);
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
        for file in files.iter_mut().skip(start) {
            if !file.binary {
                file.hunks.clear();
                file.hunks_omitted = true;
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
    let range = |range: &str| -> Option<(u32, u32)> {
        match range.split_once(',') {
            Some((start, lines)) => Some((start.parse().ok()?, lines.parse().ok()?)),
            None => Some((range.parse().ok()?, 1)),
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

        assert!(!status(&repo).unwrap().files.is_empty());
        let _ = worktree_tree(&repo);
        assert!(
            !marker.exists(),
            "ran: {}",
            std::fs::read_to_string(&marker).unwrap_or_default()
        );
    }

    /// Config that reaches git other than through `.git/config` itself: an included file, a
    /// worktree config, a submodule's own config, and a signing program (`commit-tree` is
    /// plumbing and ignores `commit.gpgSign`).
    #[test]
    fn config_from_elsewhere_runs_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        let marker = dir.path().join("ran");
        let run = |cwd: &Path, args: &[&str]| {
            let ok = Command::new("git")
                .current_dir(cwd)
                .args(args)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?}");
        };
        let evil = |tag: &str| {
            let script = dir.path().join(format!("evil-{tag}"));
            std::fs::write(
                &script,
                format!("#!/bin/sh\necho \"{tag}\" >> '{}'\ncat\n", marker.display()),
            )
            .unwrap();
            std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
                .unwrap();
            script.to_string_lossy().into_owned()
        };
        std::fs::create_dir(&repo).unwrap();
        run(&repo, &["init", "-q"]);
        run(&repo, &["config", "user.email", "t@t"]);
        run(&repo, &["config", "user.name", "t"]);
        for name in ["inc.txt", "wt.txt", "cond.txt"] {
            std::fs::write(repo.join(name), "one\n").unwrap();
        }
        // Committed, so a checkout applies them too.
        std::fs::write(
            repo.join(".gitattributes"),
            "inc.txt filter=inc\nwt.txt filter=wt\ncond.txt filter=cond\n",
        )
        .unwrap();
        // Nested repositories, as an unpacked archive holds them (no `.gitmodules`).
        let nested = |name: &str| {
            let sub = repo.join(name);
            std::fs::create_dir(&sub).unwrap();
            run(&sub, &["init", "-q"]);
            run(&sub, &["config", "user.email", "t@t"]);
            run(&sub, &["config", "user.name", "t"]);
            std::fs::write(sub.join("s.txt"), "one\n").unwrap();
            std::fs::write(sub.join(".gitattributes"), "* filter=sub\n").unwrap();
            run(&sub, &["add", "."]);
            run(&sub, &["commit", "-qm", "one"]);
            sub
        };
        let (sub, moved) = (nested("sub"), nested("moved"));
        run(&repo, &["add", "."]);
        run(&repo, &["commit", "-qm", "one"]);

        std::fs::write(
            dir.path().join("inc.cfg"),
            format!(
                "[filter \"inc\"]\n\tclean = {e}\n\tsmudge = {e}\n",
                e = evil("include")
            ),
        )
        .unwrap();
        run(&repo, &["config", "include.path", "../../inc.cfg"]);
        std::fs::write(
            dir.path().join("cond.cfg"),
            format!(
                "[filter \"cond\"]\n\tclean = {e}\n\tsmudge = {e}\n",
                e = evil("includeIf")
            ),
        )
        .unwrap();
        run(
            &repo,
            &["config", "includeIf.gitdir:/.path", "../../cond.cfg"],
        );
        run(&repo, &["config", "core.repositoryformatversion", "1"]);
        run(&repo, &["config", "extensions.worktreeConfig", "true"]);
        std::fs::write(
            repo.join(".git/config.worktree"),
            format!("[filter \"wt\"]\n\tclean = {}\n", evil("worktree-config")),
        )
        .unwrap();
        // One submodule moves to a new commit; the other has changes inside it, under its own
        // filter.
        std::fs::write(moved.join("s.txt"), "two\n").unwrap();
        run(&moved, &["commit", "-qam", "two"]);
        let moved_head = text(git(&moved, &["rev-parse", "HEAD"]).unwrap());
        run(&sub, &["config", "filter.sub.clean", &evil("submodule")]);
        std::fs::write(sub.join("s.txt"), "two\n").unwrap();
        run(&repo, &["config", "commit.gpgSign", "true"]);
        run(&repo, &["config", "gpg.program", &evil("gpg")]);
        for name in ["inc.txt", "wt.txt", "cond.txt"] {
            std::fs::write(repo.join(name), "two\n").unwrap();
        }

        assert!(!status(&repo).unwrap().files.is_empty());
        // As the repository list's counts do.
        git(&repo, &["diff", "--numstat", "-z", "HEAD", "--"]).unwrap();
        let tree = worktree_tree(&repo).unwrap();
        let in_tree = text(git(&repo, &["rev-parse", &format!("{tree}:moved")]).unwrap());
        assert_eq!(in_tree, moved_head, "a submodule is recorded at its HEAD");
        let head = text(git(&repo, &["rev-parse", "HEAD"]).unwrap());
        // As the worktree archive does.
        git(&repo, &["commit-tree", &tree, "-p", &head, "-m", "x"]).unwrap();
        let request = GitDiffRequest {
            path: repo.to_string_lossy().into_owned(),
            base: DiffBase::Head,
            files: Vec::new(),
            context: 3,
            hunks: true,
        };
        assert!(!diff(&request, &repo).unwrap().files.is_empty());
        // Checking out runs smudge filters.
        let worktree = dir.path().join("wt");
        git(
            &repo,
            &[
                "worktree",
                "add",
                "--detach",
                "--",
                &worktree.to_string_lossy(),
                "HEAD",
            ],
        )
        .unwrap();
        let ran = std::fs::read_to_string(&marker).unwrap_or_default();
        assert!(ran.is_empty(), "ran: {ran}");
    }

    #[test]
    fn lfs_filters_stay_and_others_are_emptied() {
        let listing = b"local\0filter.lfs.clean\ngit-lfs clean -- %f\0local\0filter.lfs.process\ngit-lfs filter-process\0worktree\0filter.x.smudge\nsh -c evil\0global\0filter.mine.clean\nmine\0";
        assert_eq!(
            overrides_for(listing),
            ["filter.x.smudge=", "filter.x.required=false"]
        );
    }

    #[test]
    fn parses_porcelain_v2() {
        let porcelain = b"# branch.oid 1234\0# branch.head main\0# branch.upstream origin/main\0\
# branch.ab +2 -1\0\
1 .M N... 100644 100644 100644 aaa aaa src/a b.rs\0\
2 R. N... 100644 100644 100644 bbb bbb R100 new.rs\0old.rs\0\
u UU N... 100644 100644 100644 100644 c1 c2 c3 conflict.txt\0\
? untracked.txt\0";
        let status = parse_status(Path::new("/r"), porcelain);
        assert_eq!(status.branch.as_deref(), Some("main"));
        assert_eq!(status.head.as_deref(), Some("1234"));
        assert_eq!((status.ahead, status.behind), (2, 1));
        assert_eq!(status.files.len(), 4);
        assert_eq!(status.files[0].path, "src/a b.rs");
        assert_eq!(status.files[0].unstaged, FileChange::Modified);
        assert_eq!(status.files[0].staged, FileChange::Unmodified);
        assert_eq!(status.files[1].path, "new.rs");
        assert_eq!(status.files[1].orig_path.as_deref(), Some("old.rs"));
        assert_eq!(status.files[1].staged, FileChange::Renamed);
        assert_eq!(status.files[2].staged, FileChange::Unmerged);
        assert_eq!(status.files[3].unstaged, FileChange::Untracked);
    }

    #[test]
    fn parses_hunk_headers() {
        let hunk = parse_hunk_header(b"@@ -1,3 +1 @@ fn main()").unwrap();
        assert_eq!(
            (
                hunk.old_start,
                hunk.old_lines,
                hunk.new_start,
                hunk.new_lines
            ),
            (1, 3, 1, 1)
        );
        assert_eq!(hunk.header, "fn main()");
    }
}
