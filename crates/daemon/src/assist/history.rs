//! D4: the host's command history, kept on disk and ranked by frecency.
//!
//! Every finished command from shell integration is appended to
//! `<state>/history/commands.jsonl` (mode 0600) as one JSON object:
//! `{"c": command, "d": cwd, "x": exit, "ms": duration, "t": unix ms, "n": count}`. On load the
//! records are folded into one entry per distinct command, with per-directory counts. When the
//! file grows past its cap it is rewritten from those entries (one record per command and
//! directory), so it deduplicates itself.
//!
//! On first start the shells' own histories are imported once (see [`super::histimport`]).
//!
//! Privacy: commands typed with a leading space are never recorded or imported (bash's
//! `HISTCONTROL=ignorespace`, zsh's `HIST_IGNORE_SPACE`) unless `history.ignore_space` is off.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use proto::{HistoryEntry, HistoryQuery, UnixMillis};
use serde::{Deserialize, Serialize};

use crate::core::lock;
use crate::fsutil;
use crate::identity::now_millis;

/// Directories remembered per command.
const MAX_CWDS: usize = 8;
/// Longest command line kept.
const MAX_COMMAND: usize = 8 << 10;
/// Entries a query returns at most.
const MAX_LIMIT: usize = 1000;

/// History settings (`[history]` in `config.toml`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryConfig {
    /// Record commands at all (`history.enabled`, default on).
    pub enabled: bool,
    /// Keep commands typed with a leading space out (`history.ignore_space`, default on).
    pub ignore_space: bool,
    /// Distinct commands kept; the least recently used go first (`history.max_entries`,
    /// default 50 000).
    pub max_entries: usize,
    /// Import `~/.zsh_history`, `~/.bash_history` and fish's history once
    /// (`history.import`, default on).
    pub import: bool,
}

impl Default for HistoryConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            ignore_space: true,
            max_entries: 50_000,
            import: true,
        }
    }
}

/// One line of the history file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Record {
    pub c: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub d: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ms: Option<u64>,
    pub t: u64,
    #[serde(default = "one", skip_serializing_if = "is_one")]
    pub n: u32,
}

fn one() -> u32 {
    1
}

fn is_one(n: &u32) -> bool {
    *n == 1
}

/// One distinct command.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Entry {
    command: String,
    count: u32,
    last_at: u64,
    cwd: Option<String>,
    exit: Option<i32>,
    duration_ms: Option<u64>,
    /// `(directory, count, last use)`, most recent first.
    cwds: Vec<(String, u32, u64)>,
}

impl Entry {
    fn add(&mut self, r: &Record) {
        self.count = self.count.saturating_add(r.n.max(1));
        if r.t >= self.last_at {
            self.last_at = r.t;
            if r.d.is_some() {
                self.cwd.clone_from(&r.d);
            }
            if r.x.is_some() {
                self.exit = r.x;
            }
            if r.ms.is_some() {
                self.duration_ms = r.ms;
            }
        }
        if let Some(d) = &r.d {
            match self.cwds.iter_mut().find(|(c, _, _)| c == d) {
                Some(slot) => {
                    slot.1 = slot.1.saturating_add(r.n.max(1));
                    slot.2 = slot.2.max(r.t);
                }
                None => self.cwds.push((d.clone(), r.n.max(1), r.t)),
            }
            self.cwds.sort_by_key(|c| std::cmp::Reverse(c.2));
            self.cwds.truncate(MAX_CWDS);
        }
    }

    fn records(&self) -> Vec<Record> {
        let in_cwds: u32 = self.cwds.iter().map(|c| c.1).sum();
        let mut out: Vec<Record> = self
            .cwds
            .iter()
            .map(|(d, n, t)| Record {
                c: self.command.clone(),
                d: Some(d.clone()),
                x: None,
                ms: None,
                t: *t,
                n: *n,
            })
            .collect();
        let rest = self.count.saturating_sub(in_cwds);
        if rest > 0 || out.is_empty() {
            out.push(Record {
                c: self.command.clone(),
                d: None,
                x: None,
                ms: None,
                t: self.last_at,
                n: rest.max(1),
            });
        }
        // The newest record carries the last run's details.
        if let Some(newest) = out.iter_mut().max_by_key(|r| r.t) {
            newest.x = self.exit;
            newest.ms = self.duration_ms;
            newest.d = newest.d.take().or_else(|| self.cwd.clone());
        }
        out
    }

    fn wire(&self) -> HistoryEntry {
        HistoryEntry {
            command: self.command.clone(),
            cwd: self.cwd.clone(),
            exit: self.exit,
            duration_ms: self.duration_ms,
            last_at: UnixMillis(self.last_at),
            count: self.count,
        }
    }
}

#[derive(Debug, Default)]
struct Store {
    entries: Vec<Entry>,
    index: HashMap<String, usize>,
    /// Records in the file.
    lines: usize,
    file: Option<File>,
}

impl Store {
    fn fold(&mut self, r: &Record) {
        match self.index.get(&r.c) {
            Some(&i) => self.entries[i].add(r),
            None => {
                let mut e = Entry {
                    command: r.c.clone(),
                    count: 0,
                    last_at: 0,
                    cwd: None,
                    exit: None,
                    duration_ms: None,
                    cwds: Vec::new(),
                };
                e.add(r);
                self.index.insert(r.c.clone(), self.entries.len());
                self.entries.push(e);
            }
        }
    }

    /// Keeps the `max` most recently used commands.
    fn trim(&mut self, max: usize) {
        if self.entries.len() <= max {
            return;
        }
        self.entries.sort_by_key(|e| std::cmp::Reverse(e.last_at));
        self.entries.truncate(max);
        self.reindex();
    }

    fn reindex(&mut self) {
        self.index = self
            .entries
            .iter()
            .enumerate()
            .map(|(i, e)| (e.command.clone(), i))
            .collect();
    }
}

/// The history store.
pub(crate) struct History {
    cfg: HistoryConfig,
    dir: PathBuf,
    store: Mutex<Store>,
}

/// Whether `command` may be stored under `cfg`.
pub(crate) fn admissible(cfg: &HistoryConfig, command: &str) -> bool {
    !(command.trim().is_empty()
        || command.len() > MAX_COMMAND
        || cfg.ignore_space && command.starts_with([' ', '\t']))
}

impl History {
    /// Opens (and on first use imports into) `<state_dir>/history`. Failures are logged and
    /// leave an empty in-memory history.
    pub fn open(state_dir: &Path, cfg: HistoryConfig, home: &Path) -> Self {
        let dir = state_dir.join("history");
        let history = Self {
            cfg,
            dir,
            store: Mutex::new(Store::default()),
        };
        if !history.cfg.enabled {
            return history;
        }
        if let Err(e) = history.load(home) {
            tracing::warn!("loading command history: {e}");
        }
        history
    }

    fn file(&self) -> PathBuf {
        self.dir.join("commands.jsonl")
    }

    fn load(&self, home: &Path) -> io::Result<()> {
        fsutil::create_private_dir(&self.dir)?;
        let mut store = Store::default();
        if let Some(file) = open_existing(&self.file())? {
            for line in BufReader::new(file).lines() {
                let line = line?;
                if let Ok(r) = serde_json::from_str::<Record>(&line) {
                    store.lines += 1;
                    store.fold(&r);
                }
            }
        }
        let marker = self.dir.join("imported.json");
        let mut rewrite = store.lines > self.cfg.max_entries.saturating_mul(2);
        if self.cfg.import && !marker.exists() {
            let (records, report) = super::histimport::import_all(home);
            let mut imported = 0usize;
            for r in records.iter().filter(|r| admissible(&self.cfg, &r.c)) {
                store.fold(r);
                imported += 1;
            }
            tracing::info!(imported, sources = ?report, "imported shell history");
            let marker_body = serde_json::json!({
                "at": now_millis(),
                "sources": report,
                "commands": imported,
            });
            fsutil::write_atomic(&marker, marker_body.to_string().as_bytes())?;
            rewrite = true;
        }
        store.trim(self.cfg.max_entries);
        if rewrite {
            self.rewrite(&mut store)?;
        }
        *lock(&self.store) = store;
        Ok(())
    }

    /// Rewrites the file from the folded entries, oldest first.
    fn rewrite(&self, store: &mut Store) -> io::Result<()> {
        let mut entries: Vec<&Entry> = store.entries.iter().collect();
        entries.sort_by_key(|e| e.last_at);
        let mut body = Vec::new();
        let mut lines = 0;
        for e in entries {
            for r in e.records() {
                serde_json::to_writer(&mut body, &r).map_err(io::Error::other)?;
                body.push(b'\n');
                lines += 1;
            }
        }
        fsutil::write_atomic(&self.file(), &body)?;
        store.lines = lines;
        store.file = None;
        Ok(())
    }

    /// Records a finished command. `private` commands (typed with a leading space) are
    /// skipped when `ignore_space` is on.
    pub fn record(
        &self,
        command: &str,
        private: bool,
        cwd: Option<&str>,
        exit: Option<i32>,
        duration_ms: u64,
    ) {
        if !self.cfg.enabled
            || (private && self.cfg.ignore_space)
            || !admissible(&self.cfg, command)
        {
            return;
        }
        let r = Record {
            c: command.to_owned(),
            d: cwd.map(str::to_owned),
            x: exit,
            ms: Some(duration_ms),
            t: now_millis(),
            n: 1,
        };
        let mut store = lock(&self.store);
        store.fold(&r);
        if let Err(e) = self.append(&mut store, &r) {
            tracing::warn!("appending to command history: {e}");
        }
        if store.lines > self.cfg.max_entries.saturating_mul(2) {
            store.trim(self.cfg.max_entries);
            if let Err(e) = self.rewrite(&mut store) {
                tracing::warn!("compacting command history: {e}");
            }
        }
    }

    fn append(&self, store: &mut Store, r: &Record) -> io::Result<()> {
        if store.file.is_none() {
            store.file = Some(open_append(&self.file())?);
        }
        let mut line = serde_json::to_vec(r).map_err(io::Error::other)?;
        line.push(b'\n');
        store
            .file
            .as_mut()
            .expect("opened above")
            .write_all(&line)?;
        store.lines += 1;
        Ok(())
    }

    /// Distinct commands matching `query`, best first.
    pub fn query(&self, query: &HistoryQuery) -> Vec<HistoryEntry> {
        let now = now_millis();
        let contains = query.contains.as_ref().map(|c| c.to_lowercase());
        let store = lock(&self.store);
        let mut hits: Vec<(f64, &Entry)> = store
            .entries
            .iter()
            .filter(|e| {
                query
                    .prefix
                    .as_ref()
                    .is_none_or(|p| e.command.starts_with(p.as_str()))
            })
            .filter(|e| query.since.is_none_or(|s| e.last_at >= s.0))
            .filter(|e| {
                contains
                    .as_ref()
                    .is_none_or(|c| e.command.to_lowercase().contains(c.as_str()))
            })
            .map(|e| (score(e, query.cwd.as_deref(), now), e))
            .collect();
        hits.sort_by(|a, b| b.0.total_cmp(&a.0).then(b.1.last_at.cmp(&a.1.last_at)));
        let limit = (query.limit as usize).clamp(1, MAX_LIMIT);
        hits.into_iter()
            .take(limit)
            .map(|(_, e)| e.wire())
            .collect()
    }

    /// Distinct commands stored.
    #[cfg(test)]
    pub fn len(&self) -> usize {
        lock(&self.store).entries.len()
    }
}

/// Frecency: recency bucket × log frequency × place (used in this directory, or one related
/// to it) × a penalty for a last run that failed.
fn score(e: &Entry, cwd: Option<&str>, now: u64) -> f64 {
    let hours = now.saturating_sub(e.last_at) as f64 / 3_600_000.0;
    let recency = match hours {
        h if h < 1.0 => 4.0,
        h if h < 24.0 => 2.0,
        h if h < 24.0 * 7.0 => 1.0,
        h if h < 24.0 * 30.0 => 0.5,
        _ => 0.25,
    };
    let frequency = 1.0 + f64::from(e.count).ln_1p();
    let place = cwd.map_or(1.0, |cwd| {
        let mut best: f64 = 1.0;
        for (dir, n, _) in &e.cwds {
            let weight = if dir == cwd {
                3.0 + f64::from(*n).ln_1p()
            } else if related(dir, cwd) {
                1.5
            } else {
                1.0
            };
            best = best.max(weight);
        }
        best
    });
    let failed = if e.exit.is_some_and(|x| x != 0) {
        0.7
    } else {
        1.0
    };
    recency * frequency * place * failed
}

/// One directory contains the other.
fn related(a: &str, b: &str) -> bool {
    let inside = |inner: &str, outer: &str| {
        inner
            .strip_prefix(outer)
            .is_some_and(|rest| rest.starts_with('/') || outer.ends_with('/'))
    };
    inside(a, b) || inside(b, a)
}

fn open_existing(path: &Path) -> io::Result<Option<File>> {
    match File::open(path) {
        Ok(f) => Ok(Some(f)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

fn open_append(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> HistoryConfig {
        HistoryConfig {
            import: false,
            ..HistoryConfig::default()
        }
    }

    fn q(cwd: Option<&str>, prefix: Option<&str>) -> HistoryQuery {
        HistoryQuery {
            cwd: cwd.map(Into::into),
            prefix: prefix.map(Into::into),
            contains: None,
            since: None,
            limit: 10,
        }
    }

    #[test]
    fn records_persist_dedupe_and_rank_by_directory() {
        let dir = tempfile::tempdir().unwrap();
        let h = History::open(dir.path(), cfg(), dir.path());
        h.record("make test", false, Some("/p/a"), Some(0), 1200);
        h.record("make test", false, Some("/p/a"), Some(2), 900);
        h.record("cargo build", false, Some("/p/b"), Some(0), 5000);
        h.record("cargo build", false, Some("/p/b"), Some(0), 5000);
        h.record("cargo build", false, Some("/p/b"), Some(0), 5000);
        h.record(" export SECRET=1", true, Some("/p/a"), Some(0), 1);
        let top = h.query(&q(Some("/p/a"), None));
        assert_eq!(top.len(), 2, "{top:?}");
        assert_eq!(top[0].command, "make test");
        assert_eq!(top[0].count, 2);
        assert_eq!(top[0].exit, Some(2));
        let top = h.query(&q(Some("/p/b/src"), None));
        assert_eq!(top[0].command, "cargo build");
        drop(h);

        // Reopened from disk.
        let h = History::open(dir.path(), cfg(), dir.path());
        assert_eq!(h.len(), 2);
        let mk = h.query(&q(None, Some("make")));
        assert_eq!(mk[0].count, 2);
        assert_eq!(mk[0].duration_ms, Some(900));
        assert_eq!(mk[0].cwd.as_deref(), Some("/p/a"));
    }

    #[test]
    fn compaction_keeps_counts_and_caps_entries() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = HistoryConfig {
            max_entries: 3,
            ..cfg()
        };
        let h = History::open(dir.path(), cfg.clone(), dir.path());
        for i in 0..5 {
            h.record("echo same", false, Some("/x"), Some(0), 1);
            h.record(&format!("echo {i}"), false, Some("/x"), Some(0), 1);
        }
        assert!(h.len() <= 6);
        drop(h);
        let h = History::open(dir.path(), cfg, dir.path());
        let same = h.query(&q(None, Some("echo same")));
        assert_eq!(same[0].count, 5);
        let lines = std::fs::read_to_string(dir.path().join("history/commands.jsonl"))
            .unwrap()
            .lines()
            .count();
        assert!(lines <= 8, "{lines} lines");
    }

    #[test]
    fn leading_space_is_kept_when_configured() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = HistoryConfig {
            ignore_space: false,
            ..cfg()
        };
        let h = History::open(dir.path(), cfg, dir.path());
        h.record("ls", true, None, None, 1);
        assert_eq!(h.len(), 1);
    }
}
