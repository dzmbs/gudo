//! Workflows (`proto::workflow`): YAML files of named commands with `{{arguments}}`, read
//! from `~/.config/<product>/workflows` (global) and `<repository>/.<product>/workflows` (the
//! repository a pane's directory is in).
//!
//! - **Format**: a widely used public workflow schema (`name`, `command`, `description`,
//!   `tags`, `arguments: [{name, description, default_value}]`, `shells`, `author`,
//!   `source_url`; unknown fields are ignored), plus `shell` (one shell) and `raw: true` on an
//!   argument. A file holds one workflow, or a list of them.
//! - **Safety**: files are only parsed, never run. At most [`MAX_FILES`] files of
//!   [`MAX_FILE_BYTES`] each per directory, a YAML budget against alias and nesting bombs, no
//!   tags, and error messages without source snippets (a symlink to some other file does not
//!   leak its contents).
//! - **Freshness**: a directory is re-read when its files' sizes or modification times
//!   changed since the last read, so a list is never stale even without file events.
//! - **Pushes**: every directory a list was read from is watched (non-recursively; while it
//!   does not exist, its nearest existing parent up to two levels up), and a change sends
//!   `Event::Workflows` with a new revision.
//! - **Saving** writes a new file (never replacing one) named after the workflow.

use std::collections::HashMap;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak, mpsc};
use std::time::{Duration, SystemTime};

use notify::{RecursiveMode, Watcher};
use proto::{
    Workflow, WorkflowArgument, WorkflowDraft, WorkflowList, WorkflowProblem, WorkflowScope,
    WsError,
};
use serde::Deserialize;
use tokio::sync::broadcast;

use crate::core::{Event, lock};

/// Workflow files read per directory.
pub(crate) const MAX_FILES: usize = 256;
pub(crate) const MAX_FILE_BYTES: u64 = 64 * 1024;
const MAX_NAME_CHARS: usize = 200;
const MAX_COMMAND_BYTES: usize = 16 * 1024;
/// Longest description, tag or argument text kept (longer ones are cut).
const MAX_TEXT_CHARS: usize = 2_000;
const MAX_ARGUMENTS: usize = 32;
/// Directories watched at once (the least recently listed go first).
const MAX_WATCHED: usize = 64;
/// File events are collected this long before one push.
const DEBOUNCE: Duration = Duration::from_millis(150);

/// The directory name under a repository and the config directory.
const DIR: &str = "workflows";

/// `~/.config/<product>/workflows` (`$XDG_CONFIG_HOME/<product>/workflows` when set).
pub(crate) fn global_dir(xdg_config_home: Option<&Path>, home: &Path) -> PathBuf {
    xdg_config_home
        .filter(|path| path.is_absolute())
        .map_or_else(|| home.join(".config"), Path::to_owned)
        .join(brand::DIR_NAME)
        .join(DIR)
}

/// `<root>/.<product>/workflows`.
fn repo_dir(root: &Path) -> PathBuf {
    root.join(format!(".{}", brand::DIR_NAME)).join(DIR)
}

/// The repository a directory is in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RepoDirs {
    /// Top level of the worktree.
    pub worktree: PathBuf,
    /// The main worktree, when `worktree` is a linked one.
    pub main: Option<PathBuf>,
}

impl RepoDirs {
    /// The repository's name: its main worktree's directory name.
    fn name(&self) -> Option<String> {
        let top = self.main.as_deref().unwrap_or(&self.worktree);
        top.file_name()
            .map(|name| name.to_string_lossy().into_owned())
    }

    /// The workflow directory to read and save into: the worktree's when it has one, else the
    /// main worktree's (workflows kept untracked in the main checkout), else the worktree's.
    fn workflow_dir(&self) -> PathBuf {
        let own = repo_dir(&self.worktree);
        if own.is_dir() {
            return own;
        }
        self.main
            .as_deref()
            .map(repo_dir)
            .filter(|dir| dir.is_dir())
            .unwrap_or(own)
    }
}

/// The repository `dir` is in: the nearest ancestor with a `.git` directory or file.
pub(crate) fn repo_of(dir: &Path) -> Option<RepoDirs> {
    dir.ancestors().find_map(|ancestor| {
        let git = ancestor.join(".git");
        let metadata = fs::symlink_metadata(&git).ok()?;
        if metadata.is_dir() {
            Some(RepoDirs {
                worktree: ancestor.to_owned(),
                main: None,
            })
        } else if metadata.is_file() {
            Some(RepoDirs {
                worktree: ancestor.to_owned(),
                main: main_worktree(&git).filter(|main| main != ancestor),
            })
        } else {
            None
        }
    })
}

/// A linked worktree's main worktree, from its `.git` file (`gitdir: …`) and the git
/// directory's `commondir`. `None` for submodules and anything unexpected.
fn main_worktree(git_file: &Path) -> Option<PathBuf> {
    let text = read_small(git_file, 4096)?;
    let gitdir = text
        .lines()
        .find_map(|line| line.strip_prefix("gitdir:"))?
        .trim();
    let gitdir = git_file.parent()?.join(gitdir);
    let common = read_small(&gitdir.join("commondir"), 4096)?;
    let common = gitdir.join(common.trim()).canonicalize().ok()?;
    (common.file_name()? == ".git").then(|| common.parent().map(Path::to_owned))?
}

fn read_small(path: &Path, max_len: u64) -> Option<String> {
    let metadata = fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > max_len {
        return None;
    }
    fs::read_to_string(path).ok()
}

/// A scalar read as text: workflow files write `default_value: 8080` as often as `"8080"`.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Text(String);

impl<'de> Deserialize<'de> for Text {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct TextVisitor;
        impl serde::de::Visitor<'_> for TextVisitor {
            type Value = Text;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("text")
            }
            fn visit_str<E>(self, value: &str) -> Result<Text, E> {
                Ok(Text(value.to_owned()))
            }
            fn visit_bool<E>(self, value: bool) -> Result<Text, E> {
                Ok(Text(value.to_string()))
            }
            fn visit_i64<E>(self, value: i64) -> Result<Text, E> {
                Ok(Text(value.to_string()))
            }
            fn visit_u64<E>(self, value: u64) -> Result<Text, E> {
                Ok(Text(value.to_string()))
            }
            fn visit_f64<E>(self, value: f64) -> Result<Text, E> {
                Ok(Text(value.to_string()))
            }
        }
        deserializer.deserialize_any(TextVisitor)
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct FileWorkflow {
    name: Option<Text>,
    command: Option<Text>,
    description: Option<Text>,
    tags: Option<Vec<Text>>,
    arguments: Option<Vec<FileArgument>>,
    shells: Option<Vec<Text>>,
    shell: Option<Text>,
    author: Option<Text>,
    source_url: Option<Text>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct FileArgument {
    name: Option<Text>,
    description: Option<Text>,
    default_value: Option<Text>,
    raw: Option<bool>,
}

fn yaml_options() -> serde_saphyr::Options {
    let mut budget = serde_saphyr::Budget::default();
    budget.max_events = 50_000;
    budget.max_aliases = 64;
    budget.max_anchors = 64;
    budget.max_depth = 16;
    budget.max_documents = 4;
    budget.max_nodes = 20_000;
    budget.max_total_scalar_bytes = 2 * MAX_FILE_BYTES as usize;
    budget.max_merge_keys = 16;
    let mut options = serde_saphyr::Options::default();
    options.budget = Some(budget);
    // No snippets of the source in error messages (they go to clients).
    options.with_snippet = false;
    options.reject_unsupported_tags = true;
    options
}

/// The workflows of one file's text (`path` names them).
pub(crate) fn parse(
    text: &str,
    path: &Path,
    scope: WorkflowScope,
) -> Result<Vec<Workflow>, String> {
    let options = yaml_options();
    let documents = match serde_saphyr::from_str_with_options::<FileWorkflow>(text, options.clone())
    {
        Ok(one) => vec![one],
        Err(one_error) => serde_saphyr::from_str_with_options::<Vec<FileWorkflow>>(text, options)
            .map_err(|_| one_line(&one_error.to_string()))?,
    };
    let many = documents.len() > 1;
    let shown = path.to_string_lossy();
    documents
        .into_iter()
        .enumerate()
        .map(|(index, document)| {
            let id = if many {
                format!("{shown}#{index}")
            } else {
                shown.clone().into_owned()
            };
            let stem = path
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned());
            from_file(document, id, stem, scope, &shown).map_err(|error| {
                if many {
                    format!("workflow {}: {error}", index + 1)
                } else {
                    error
                }
            })
        })
        .collect()
}

fn from_file(
    document: FileWorkflow,
    id: String,
    stem: Option<String>,
    scope: WorkflowScope,
    path: &str,
) -> Result<Workflow, String> {
    let text = |value: Option<Text>| {
        value
            .map(|value| value.0.trim().to_owned())
            .filter(|value| !value.is_empty())
            .map(|value| cut(&value, MAX_TEXT_CHARS))
    };
    let list = |values: Option<Vec<Text>>| -> Vec<String> {
        values
            .unwrap_or_default()
            .into_iter()
            .filter_map(|value| text(Some(value)))
            .take(MAX_ARGUMENTS)
            .collect()
    };
    let command = document
        .command
        .map(|command| command.0.trim_end_matches(['\n', '\r']).to_owned())
        .filter(|command| !command.trim().is_empty())
        .ok_or("no command")?;
    if command.len() > MAX_COMMAND_BYTES {
        return Err(format!("command longer than {MAX_COMMAND_BYTES} bytes"));
    }
    let name = text(document.name).or(stem).ok_or("no name")?;
    if name.chars().count() > MAX_NAME_CHARS {
        return Err(format!("name longer than {MAX_NAME_CHARS} characters"));
    }
    let mut arguments = Vec::new();
    for argument in document.arguments.unwrap_or_default() {
        let argument_name = argument
            .name
            .map(|name| name.0.trim().to_owned())
            .ok_or("an argument has no name")?;
        if !proto::workflow::is_name(&argument_name) {
            return Err(format!(
                "argument name {argument_name:?} is not a placeholder name"
            ));
        }
        if arguments
            .iter()
            .any(|existing: &WorkflowArgument| existing.name == argument_name)
        {
            continue;
        }
        arguments.push(WorkflowArgument {
            name: argument_name,
            description: text(argument.description),
            // A default may be meaningfully blank or padded: keep it as written.
            default_value: argument
                .default_value
                .map(|value| cut(&value.0, MAX_TEXT_CHARS)),
            raw: argument.raw.unwrap_or(false),
        });
    }
    for placeholder in proto::placeholders(&command) {
        if !arguments
            .iter()
            .any(|argument| argument.name == placeholder)
        {
            arguments.push(WorkflowArgument {
                name: placeholder.to_owned(),
                description: None,
                default_value: None,
                raw: false,
            });
        }
    }
    if arguments.len() > MAX_ARGUMENTS {
        return Err(format!("more than {MAX_ARGUMENTS} arguments"));
    }
    let mut shells = list(document.shells);
    if let Some(shell) = text(document.shell)
        && !shells.contains(&shell)
    {
        shells.push(shell);
    }
    Ok(Workflow {
        id,
        name,
        command,
        description: text(document.description),
        tags: list(document.tags),
        arguments,
        shells,
        author: text(document.author),
        source_url: text(document.source_url),
        scope,
        path: path.to_owned(),
    })
}

fn cut(text: &str, max_chars: usize) -> String {
    match text.char_indices().nth(max_chars) {
        Some((at, _)) => text[..at].to_owned(),
        None => text.to_owned(),
    }
}

fn one_line(text: &str) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("not valid YAML");
    cut(line, 200)
}

/// What one directory held.
#[derive(Debug, Default, Clone)]
pub(crate) struct DirRead {
    pub workflows: Vec<Workflow>,
    pub problems: Vec<WorkflowProblem>,
}

/// The files that make up a directory's content: name, size and modification time.
type Signature = Vec<(String, u64, Option<SystemTime>)>;

/// The workflow files of `dir` (sorted, at most [`MAX_FILES`]) and the directory's signature.
fn files(dir: &Path) -> (Vec<PathBuf>, Signature) {
    let Ok(entries) = fs::read_dir(dir) else {
        return (Vec::new(), Vec::new());
    };
    let mut found: Vec<(String, PathBuf, u64, Option<SystemTime>)> = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let extension = Path::new(&name)
                .extension()?
                .to_string_lossy()
                .to_ascii_lowercase();
            if name.starts_with('.') || !matches!(extension.as_str(), "yaml" | "yml") {
                return None;
            }
            // Follows symlinks: a repository may link shared workflows in.
            let metadata = fs::metadata(entry.path()).ok()?;
            metadata
                .is_file()
                .then(|| (name, entry.path(), metadata.len(), metadata.modified().ok()))
        })
        .collect();
    found.sort_by(|a, b| a.0.cmp(&b.0));
    found.truncate(MAX_FILES);
    let signature = found
        .iter()
        .map(|(name, _, len, modified)| (name.clone(), *len, *modified))
        .collect();
    (
        found.into_iter().map(|(_, path, ..)| path).collect(),
        signature,
    )
}

#[cfg(test)]
pub(crate) fn read_dir(dir: &Path, scope: WorkflowScope) -> DirRead {
    let (paths, _) = files(dir);
    read_files(&paths, scope)
}

fn read_files(paths: &[PathBuf], scope: WorkflowScope) -> DirRead {
    let mut out = DirRead::default();
    for path in paths {
        let problem = |message: String| WorkflowProblem {
            path: path.to_string_lossy().into_owned(),
            message,
        };
        match read_file(path) {
            Ok(text) => match parse(&text, path, scope) {
                Ok(found) => out.workflows.extend(found),
                Err(error) => out.problems.push(problem(error)),
            },
            Err(error) => out.problems.push(problem(error)),
        }
    }
    out.workflows
        .sort_by_key(|workflow| workflow.name.to_lowercase());
    out
}

fn read_file(path: &Path) -> Result<String, String> {
    let metadata = fs::metadata(path).map_err(|error| error.to_string())?;
    if metadata.len() > MAX_FILE_BYTES {
        return Err(format!("larger than {} KiB", MAX_FILE_BYTES / 1024));
    }
    let bytes = fs::read(path).map_err(|error| error.to_string())?;
    String::from_utf8(bytes).map_err(|_| "not UTF-8 text".to_owned())
}

/// `path` with its longest existing prefix resolved (FSEvents reports real paths).
fn canonical(path: &Path) -> PathBuf {
    let mut rest = Vec::new();
    let mut existing = path;
    loop {
        if let Ok(real) = existing.canonicalize() {
            return rest
                .iter()
                .rev()
                .fold(real, |joined, component| joined.join(component));
        }
        match (existing.parent(), existing.file_name()) {
            (Some(parent), Some(name)) => {
                rest.push(name.to_owned());
                existing = parent;
            }
            _ => return path.to_owned(),
        }
    }
}

struct Cached {
    signature: Signature,
    read: Arc<DirRead>,
}

#[derive(Default)]
struct Inner {
    cache: HashMap<PathBuf, Cached>,
    watcher: Option<notify::RecommendedWatcher>,
    /// Directories of interest, least recently listed first.
    targets: Vec<PathBuf>,
    /// What is watched for each target (itself or an existing parent).
    armed: HashMap<PathBuf, PathBuf>,
    /// How many targets each watched path serves.
    watched: HashMap<PathBuf, usize>,
}

struct Shared {
    inner: Mutex<Inner>,
    revision: AtomicU64,
    events: broadcast::Sender<Event>,
}

/// The daemon's workflow directories: cached reads, watches and the revision.
pub(crate) struct Workflows {
    shared: Arc<Shared>,
}

impl Workflows {
    pub fn new(events: broadcast::Sender<Event>) -> Self {
        Self {
            shared: Arc::new(Shared {
                inner: Mutex::new(Inner::default()),
                revision: AtomicU64::new(1),
                events,
            }),
        }
    }

    pub fn rev(&self) -> u64 {
        self.shared.revision.load(Ordering::Relaxed)
    }

    /// The workflows of `global` and, for a pane in a repository, the repository's (blocking).
    pub fn list(&self, global: &Path, cwd: Option<&Path>) -> WorkflowList {
        let repo = cwd.and_then(repo_of);
        let mut workflows = Vec::new();
        let mut problems = Vec::new();
        if let Some(repo) = &repo {
            let read = self.read(&repo.workflow_dir(), WorkflowScope::Repo);
            workflows.extend(read.workflows.iter().cloned());
            problems.extend(read.problems.iter().cloned());
            // Watch the worktree's own directory too, so creating it is noticed.
            self.watch(&repo_dir(&repo.worktree));
        }
        let read = self.read(global, WorkflowScope::Global);
        workflows.extend(read.workflows.iter().cloned());
        problems.extend(read.problems.iter().cloned());
        WorkflowList {
            rev: self.rev(),
            repo: repo
                .as_ref()
                .map(|repo| repo.worktree.to_string_lossy().into_owned()),
            repo_name: repo.as_ref().and_then(RepoDirs::name),
            workflows,
            problems,
        }
    }

    /// Writes `draft` as a new file in `global` or the repository of `cwd`; the workflow as
    /// read back (blocking).
    pub fn save(
        &self,
        scope: WorkflowScope,
        draft: &WorkflowDraft,
        global: &Path,
        cwd: Option<&Path>,
    ) -> Result<Workflow, WsError> {
        let dir = match scope {
            WorkflowScope::Global => global.to_owned(),
            WorkflowScope::Repo => cwd
                .and_then(repo_of)
                .map(|repo| repo.workflow_dir())
                .ok_or_else(|| WsError::NotFound("the pane is not in a git repository".into()))?,
        };
        validate(draft)?;
        let yaml = to_yaml(draft);
        // Only what we would accept when reading it back is written.
        parse(&yaml, Path::new("draft.yaml"), scope).map_err(WsError::Invalid)?;
        fs::create_dir_all(&dir)
            .map_err(|error| WsError::Failed(format!("{}: {error}", dir.display())))?;
        let slug = slug(&draft.name);
        let mut written = None;
        for n in 1..=100 {
            let name = if n == 1 {
                format!("{slug}.yaml")
            } else {
                format!("{slug}-{n}.yaml")
            };
            let path = dir.join(name);
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(mut file) => {
                    file.write_all(yaml.as_bytes())
                        .map_err(|error| WsError::Failed(format!("{}: {error}", path.display())))?;
                    written = Some(path);
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => {
                    return Err(WsError::Failed(format!("{}: {error}", path.display())));
                }
            }
        }
        let path =
            written.ok_or_else(|| WsError::Conflict(format!("too many workflows named {slug}")))?;
        let text = read_file(&path).map_err(WsError::Failed)?;
        let saved = parse(&text, &path, scope)
            .map_err(WsError::Failed)?
            .into_iter()
            .next()
            .ok_or_else(|| WsError::Failed("the file holds no workflow".into()))?;
        self.changed();
        self.watch(&dir);
        Ok(saved)
    }

    /// A directory's workflows, re-read only when its files changed.
    fn read(&self, dir: &Path, scope: WorkflowScope) -> Arc<DirRead> {
        self.watch(dir);
        let (paths, signature) = files(dir);
        {
            let inner = lock(&self.shared.inner);
            if let Some(cached) = inner.cache.get(dir)
                && cached.signature == signature
            {
                return Arc::clone(&cached.read);
            }
        }
        let read = Arc::new(read_files(&paths, scope));
        let mut inner = lock(&self.shared.inner);
        if inner.cache.len() >= 2 * MAX_WATCHED {
            inner.cache.clear();
        }
        inner.cache.insert(
            dir.to_owned(),
            Cached {
                signature,
                read: Arc::clone(&read),
            },
        );
        read
    }

    /// Bumps the revision and tells the clients.
    fn changed(&self) {
        notify_changed(&self.shared);
    }

    /// Starts watching `dir` (or its nearest existing parent) for pushes.
    fn watch(&self, dir: &Path) {
        let target = canonical(dir);
        let mut inner = lock(&self.shared.inner);
        if let Some(index) = inner.targets.iter().position(|known| *known == target) {
            let known = inner.targets.remove(index);
            inner.targets.push(known);
            return;
        }
        if inner.watcher.is_none() {
            match start_watcher(Arc::downgrade(&self.shared)) {
                Ok(watcher) => inner.watcher = Some(watcher),
                Err(error) => {
                    tracing::info!("workflow watcher: {error}");
                    return;
                }
            }
        }
        inner.targets.push(target);
        while inner.targets.len() > MAX_WATCHED {
            let oldest = inner.targets.remove(0);
            disarm(&mut inner, &oldest);
        }
        rearm(&mut inner);
    }
}

fn notify_changed(shared: &Shared) {
    let revision = shared.revision.fetch_add(1, Ordering::Relaxed) + 1;
    let _ = shared.events.send(Event::Workflows(revision));
}

fn validate(draft: &WorkflowDraft) -> Result<(), WsError> {
    let invalid = |message: String| Err(WsError::Invalid(message));
    if draft.name.trim().is_empty() {
        return invalid("a workflow needs a name".into());
    }
    if draft.name.chars().count() > MAX_NAME_CHARS {
        return invalid(format!(
            "the name is longer than {MAX_NAME_CHARS} characters"
        ));
    }
    if draft.command.trim().is_empty() {
        return invalid("a workflow needs a command".into());
    }
    if draft.command.len() > MAX_COMMAND_BYTES {
        return invalid(format!(
            "the command is longer than {MAX_COMMAND_BYTES} bytes"
        ));
    }
    if draft.arguments.len() > MAX_ARGUMENTS {
        return invalid(format!("more than {MAX_ARGUMENTS} arguments"));
    }
    if let Some(argument) = draft
        .arguments
        .iter()
        .find(|argument| !proto::workflow::is_name(&argument.name))
    {
        return invalid(format!("{:?} is not a placeholder name", argument.name));
    }
    Ok(())
}

/// A file name for a workflow: lowercase letters and digits joined by `-`.
fn slug(name: &str) -> String {
    let mut out = String::new();
    for ch in name.chars().flat_map(char::to_lowercase) {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
        } else if !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
        if out.len() >= 60 {
            break;
        }
    }
    let out = out.trim_end_matches('-');
    if out.is_empty() {
        "workflow".to_owned()
    } else {
        out.to_owned()
    }
}

/// `text` as a YAML double-quoted scalar: `"`, `\` and everything outside YAML's printable set
/// escaped.
fn yaml_quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            ch if ch.is_control() || matches!(ch, '\u{feff}' | '\u{fffe}' | '\u{ffff}') => {
                out.push_str(&format!("\\u{:04x}", u32::from(ch)));
            }
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

/// The YAML of a draft. Strings are written double-quoted, a multi-line command as a literal
/// block when that keeps it exact.
pub(crate) fn to_yaml(draft: &WorkflowDraft) -> String {
    let quote = yaml_quote;
    let mut out = String::from("---\n");
    out.push_str(&format!("name: {}\n", quote(&draft.name)));
    let command = &draft.command;
    let block = command.contains('\n')
        && !command.ends_with('\n')
        && !command.starts_with([' ', '\t', '\n'])
        && !command
            .chars()
            .any(|ch| ch.is_control() && ch != '\n' && ch != '\t')
        && !command.lines().any(|line| line.ends_with([' ', '\t']));
    if block {
        out.push_str("command: |-\n");
        for line in command.split('\n') {
            if line.is_empty() {
                out.push('\n');
            } else {
                out.push_str(&format!("  {line}\n"));
            }
        }
    } else {
        out.push_str(&format!("command: {}\n", quote(command)));
    }
    if let Some(description) = draft
        .description
        .as_deref()
        .filter(|description| !description.trim().is_empty())
    {
        out.push_str(&format!("description: {}\n", quote(description)));
    }
    let list = |out: &mut String, key: &str, items: &[String]| {
        if !items.is_empty() {
            out.push_str(&format!("{key}:\n"));
            for item in items {
                out.push_str(&format!("  - {}\n", quote(item)));
            }
        }
    };
    list(&mut out, "tags", &draft.tags);
    if !draft.arguments.is_empty() {
        out.push_str("arguments:\n");
        for argument in &draft.arguments {
            out.push_str(&format!("  - name: {}\n", quote(&argument.name)));
            if let Some(description) = &argument.description {
                out.push_str(&format!("    description: {}\n", quote(description)));
            }
            if let Some(default_value) = &argument.default_value {
                out.push_str(&format!("    default_value: {}\n", quote(default_value)));
            }
            if argument.raw {
                out.push_str("    raw: true\n");
            }
        }
    }
    list(&mut out, "shells", &draft.shells);
    out
}

/// What to watch for `target`: itself, else its parent or grandparent, whichever exists first.
fn watch_point(target: &Path) -> Option<PathBuf> {
    target
        .ancestors()
        .take(3)
        .find(|path| path.is_dir())
        .map(Path::to_owned)
}

fn rearm(inner: &mut Inner) {
    let targets = inner.targets.clone();
    for target in targets {
        let wanted = watch_point(&target);
        if inner.armed.get(&target) == wanted.as_ref() {
            continue;
        }
        disarm(inner, &target);
        let Some(point) = wanted else { continue };
        let count = inner.watched.entry(point.clone()).or_insert(0);
        if *count == 0
            && let Some(watcher) = inner.watcher.as_mut()
            && let Err(error) = watcher.watch(&point, RecursiveMode::NonRecursive)
        {
            tracing::debug!("watching {}: {error}", point.display());
            inner.watched.remove(&point);
            continue;
        }
        *inner.watched.entry(point.clone()).or_insert(0) += 1;
        inner.armed.insert(target, point);
    }
}

fn disarm(inner: &mut Inner, target: &Path) {
    let Some(point) = inner.armed.remove(target) else {
        return;
    };
    let Some(count) = inner.watched.get_mut(&point) else {
        return;
    };
    *count -= 1;
    if *count == 0 {
        inner.watched.remove(&point);
        if let Some(watcher) = inner.watcher.as_mut() {
            let _ = watcher.unwatch(&point);
        }
    }
}

/// Whether a changed path concerns a target: inside it, or one of the directories on the way
/// to it (created or removed).
fn concerns(path: &Path, target: &Path) -> bool {
    path.starts_with(target) || target.starts_with(path)
}

fn start_watcher(shared: Weak<Shared>) -> notify::Result<notify::RecommendedWatcher> {
    let (tx, rx) = mpsc::channel::<Vec<PathBuf>>();
    let watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
        // An error (overflow) may hide a change: treat it as one everywhere.
        let _ = tx.send(result.map(|event| event.paths).unwrap_or_default());
    })?;
    std::thread::Builder::new()
        .name("workflows-watch".into())
        .spawn(move || {
            while let Ok(first) = rx.recv() {
                let mut paths = first.clone();
                let mut everything = first.is_empty();
                while let Ok(more) = rx.recv_timeout(DEBOUNCE) {
                    everything |= more.is_empty();
                    paths.extend(more);
                }
                let Some(shared) = shared.upgrade() else {
                    return;
                };
                let relevant = {
                    let mut inner = lock(&shared.inner);
                    let relevant = everything
                        || paths
                            .iter()
                            .any(|path| inner.targets.iter().any(|target| concerns(path, target)));
                    if relevant {
                        // A directory on the way may have appeared: watch closer.
                        rearm(&mut inner);
                    }
                    relevant
                };
                if relevant {
                    notify_changed(&shared);
                }
            }
        })
        .map_err(|error| notify::Error::generic(&error.to_string()))?;
    Ok(watcher)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn public_schema_file() -> &'static str {
        r#"---
name: Check out a branch
command: "git checkout {{branch_name}}"
tags:
  - git
description: Switches to another branch.
arguments:
  - name: branch_name
    description: The branch to switch to
    default_value: ~
source_url: "https://example.com/x"
author: Someone
author_url: "https://example.com/someone"
shells: []
"#
    }

    #[test]
    fn parses_public_schema_files() {
        let workflows = parse(
            public_schema_file(),
            Path::new("/w/checkout.yaml"),
            WorkflowScope::Global,
        )
        .unwrap();
        assert_eq!(workflows.len(), 1);
        let workflow = &workflows[0];
        assert_eq!(workflow.name, "Check out a branch");
        assert_eq!(workflow.command, "git checkout {{branch_name}}");
        assert_eq!(workflow.tags, ["git"]);
        assert_eq!(
            workflow.description.as_deref(),
            Some("Switches to another branch.")
        );
        assert_eq!(workflow.arguments.len(), 1);
        assert_eq!(workflow.arguments[0].name, "branch_name");
        assert_eq!(workflow.arguments[0].default_value, None);
        assert!(!workflow.arguments[0].raw);
        assert_eq!(workflow.author.as_deref(), Some("Someone"));
        assert_eq!(
            workflow.source_url.as_deref(),
            Some("https://example.com/x")
        );
        assert_eq!(workflow.id, "/w/checkout.yaml");
        assert_eq!(workflow.path, "/w/checkout.yaml");
        assert_eq!(workflow.scope, WorkflowScope::Global);
    }

    #[test]
    fn lists_numbers_raw_shell_and_missing_arguments() {
        let text = r#"
- name: Serve
  command: |
    python3 -m http.server {{port}} {{extra}}
  arguments:
    - name: port
      default_value: 8080
    - name: extra
      raw: true
  shell: zsh
- command: echo {{ who }}
"#;
        let workflows = parse(text, Path::new("/r/many.yml"), WorkflowScope::Repo).unwrap();
        assert_eq!(workflows.len(), 2);
        assert_eq!(workflows[0].id, "/r/many.yml#0");
        assert_eq!(
            workflows[0].command,
            "python3 -m http.server {{port}} {{extra}}"
        );
        assert_eq!(
            workflows[0].arguments[0].default_value.as_deref(),
            Some("8080")
        );
        assert!(workflows[0].arguments[1].raw);
        assert_eq!(workflows[0].shells, ["zsh"]);
        // No name: the file's; the placeholder becomes an argument.
        assert_eq!(workflows[1].name, "many");
        assert_eq!(workflows[1].arguments[0].name, "who");
    }

    #[test]
    fn rejects_bad_files_with_short_messages() {
        let path = Path::new("/x.yaml");
        assert_eq!(
            parse("name: x\n", path, WorkflowScope::Global).unwrap_err(),
            "no command"
        );
        assert!(parse("command: [unclosed\n", path, WorkflowScope::Global).is_err());
        let bad_argument = "command: echo\narguments:\n  - name: \"no spaces\"\n";
        assert!(parse(bad_argument, path, WorkflowScope::Global).is_err());
        // A billion laughs is cut off by the budget.
        let mut bomb = String::from("a: &a [x,x,x,x,x,x,x,x,x,x]\n");
        for n in 0..9 {
            let previous = if n == 0 {
                "a".to_owned()
            } else {
                format!("b{}", n - 1)
            };
            bomb.push_str(&format!(
                "b{n}: &b{n} [*{previous},*{previous},*{previous},*{previous},*{previous},*{previous},*{previous},*{previous},*{previous},*{previous}]\n"
            ));
        }
        bomb.push_str("command: echo\n");
        assert!(parse(&bomb, path, WorkflowScope::Global).is_err());
        // Tags that would construct objects elsewhere are refused.
        assert!(
            parse(
                "command: !!python/object:os.system echo\n",
                path,
                WorkflowScope::Global
            )
            .is_err()
        );
        // Messages carry no source snippet.
        let secret = "command: echo\nname: [SECRET-LINE\n";
        let message = parse(secret, path, WorkflowScope::Global).unwrap_err();
        assert!(!message.contains("SECRET"), "{message}");
        assert!(!message.contains('\n'));
    }

    #[test]
    fn yaml_round_trips() {
        let drafts = [
            WorkflowDraft {
                name: "Deploy \"prod\": it's #1".into(),
                command: "kubectl rollout restart deploy/{{name}} -n {{ns}}\necho 'done: ok' # x"
                    .into(),
                description: Some("Restarts: a deployment\nand waits".into()),
                tags: vec!["k8s".into(), "- odd".into()],
                arguments: vec![WorkflowArgument {
                    name: "ns".into(),
                    description: Some("Namespace".into()),
                    default_value: Some(" default ".into()),
                    raw: true,
                }],
                shells: vec!["zsh".into()],
            },
            WorkflowDraft {
                name: "x".into(),
                command: "  leading\n\ttabbed \nend\n".into(),
                description: None,
                tags: vec![],
                arguments: vec![],
                shells: vec![],
            },
            WorkflowDraft {
                name: "unicode ✓".into(),
                command: "echo \u{1b}[1m\u{7f} ✓ \\ \"q\"".into(),
                description: None,
                tags: vec![],
                arguments: vec![],
                shells: vec![],
            },
        ];
        for draft in drafts {
            let yaml = to_yaml(&draft);
            let parsed = parse(&yaml, Path::new("/d.yaml"), WorkflowScope::Repo)
                .unwrap_or_else(|error| panic!("{error}\n{yaml}"));
            let workflow = &parsed[0];
            assert_eq!(workflow.name, draft.name, "{yaml}");
            assert_eq!(
                workflow.command,
                draft.command.trim_end_matches('\n'),
                "{yaml}"
            );
            assert_eq!(workflow.description, draft.description, "{yaml}");
            assert_eq!(workflow.tags, draft.tags, "{yaml}");
            assert_eq!(workflow.shells, draft.shells, "{yaml}");
            for argument in &draft.arguments {
                assert!(workflow.arguments.contains(argument), "{yaml}");
            }
        }
    }

    #[test]
    fn slugs() {
        assert_eq!(slug("Deploy to Prod!"), "deploy-to-prod");
        assert_eq!(slug("  ✓✓ "), "workflow");
        assert_eq!(slug("a/b c"), "a-b-c");
        assert!(slug(&"x".repeat(500)).len() <= 60);
    }

    #[test]
    fn finds_repositories_and_linked_worktrees() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let main = root.join("main");
        fs::create_dir_all(main.join(".git/worktrees/wt")).unwrap();
        fs::create_dir_all(main.join("src/deep")).unwrap();
        let linked = root.join("wt");
        fs::create_dir_all(linked.join("sub")).unwrap();
        fs::write(
            linked.join(".git"),
            format!("gitdir: {}\n", main.join(".git/worktrees/wt").display()),
        )
        .unwrap();
        fs::write(main.join(".git/worktrees/wt/commondir"), "../..\n").unwrap();

        let repo = repo_of(&main.join("src/deep")).unwrap();
        assert_eq!(repo.worktree, main);
        assert_eq!(repo.main, None);
        assert_eq!(repo.name().as_deref(), Some("main"));

        let repo = repo_of(&linked.join("sub")).unwrap();
        assert_eq!(repo.worktree, linked);
        assert_eq!(repo.main.as_deref(), Some(main.as_path()));
        assert_eq!(repo.name().as_deref(), Some("main"));
        // No directory of its own: the main worktree's.
        fs::create_dir_all(repo_dir(&main)).unwrap();
        assert_eq!(repo.workflow_dir(), repo_dir(&main));
        fs::create_dir_all(repo_dir(&linked)).unwrap();
        assert_eq!(repo.workflow_dir(), repo_dir(&linked));

        assert!(repo_of(&root).is_none());
    }

    #[test]
    fn reads_directories_with_limits() {
        let temp = tempfile::tempdir().unwrap();
        let dir = temp.path();
        fs::write(dir.join("b.yaml"), "name: Beta\ncommand: echo b\n").unwrap();
        fs::write(dir.join("a.YML"), "name: alpha\ncommand: echo a\n").unwrap();
        fs::write(dir.join(".hidden.yaml"), "name: h\ncommand: h\n").unwrap();
        fs::write(dir.join("notes.txt"), "name: n\ncommand: n\n").unwrap();
        fs::write(dir.join("broken.yaml"), "name: [\n").unwrap();
        let big = format!(
            "name: big\ncommand: echo\ndescription: {}\n",
            "x".repeat(70_000)
        );
        fs::write(dir.join("big.yaml"), big).unwrap();
        let read = read_dir(dir, WorkflowScope::Global);
        let names: Vec<_> = read
            .workflows
            .iter()
            .map(|workflow| workflow.name.as_str())
            .collect();
        assert_eq!(names, ["alpha", "Beta"]);
        assert_eq!(read.problems.len(), 2);
        assert!(read.problems.iter().any(|problem| {
            problem.path.ends_with("big.yaml") && problem.message.contains("64 KiB")
        }));
    }

    #[test]
    fn concerns_only_the_target_and_the_way_there() {
        let target = Path::new("/r/.gudo/workflows");
        assert!(concerns(Path::new("/r/.gudo/workflows/a.yaml"), target));
        assert!(concerns(Path::new("/r/.gudo"), target));
        assert!(!concerns(Path::new("/r/src/main.rs"), target));
        assert!(!concerns(Path::new("/r/.gudo/other"), target));
    }

    #[test]
    fn global_dir_follows_xdg() {
        let home = Path::new("/home/u");
        assert_eq!(
            global_dir(None, home),
            Path::new("/home/u/.config")
                .join(brand::DIR_NAME)
                .join("workflows")
        );
        assert_eq!(
            global_dir(Some(Path::new("/x")), home),
            Path::new("/x").join(brand::DIR_NAME).join("workflows")
        );
        assert_eq!(
            global_dir(Some(Path::new("rel")), home),
            global_dir(None, home)
        );
    }
}
