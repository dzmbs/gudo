//! One-time import of the shells' own history files into the daemon's history.
//!
//! - zsh (`$ZDOTDIR/.zsh_history`, `~/.zsh_history`, `~/.histfile`): plain or extended
//!   (`: <start>:<elapsed>;<command>`) lines, multi-line commands continued with a trailing
//!   backslash, and zsh's metafied bytes (`0x83` followed by the byte xor 32).
//! - bash (`~/.bash_history`): one command per line, with optional `#<epoch>` timestamp lines.
//! - fish (`$XDG_DATA_HOME/fish/fish_history`, `~/.local/share/fish/fish_history`): `- cmd:`
//!   entries with `when:` timestamps; `\n` and `\\` escapes.
//!
//! Lines without a timestamp get the file's modification time, spaced a second apart in file
//! order, so their relative recency survives. Each distinct command becomes one record whose
//! count is the number of times it occurs.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::Serialize;

use super::history::Record;

/// Largest history file read.
const MAX_FILE: u64 = 64 << 20;

/// What one source contributed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct Source {
    pub shell: &'static str,
    pub path: PathBuf,
    pub commands: usize,
}

/// One parsed history line: the command and its time in Unix seconds, if recorded.
type Line = (String, Option<u64>);

/// A history file format's parser.
type Parser = fn(&[u8]) -> Vec<Line>;

/// Imports every history file found under `home`.
pub(crate) fn import_all(home: &Path) -> (Vec<Record>, Vec<Source>) {
    let xdg_data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|dir| dir.starts_with(home))
        .unwrap_or_else(|| home.join(".local/share"));
    let mut zsh = vec![home.join(".zsh_history"), home.join(".histfile")];
    if let Some(zdotdir) = std::env::var_os("ZDOTDIR").map(PathBuf::from)
        && zdotdir.starts_with(home)
    {
        zsh.insert(0, zdotdir.join(".zsh_history"));
    }
    let sources: [(&'static str, Vec<PathBuf>, Parser); 3] = [
        ("zsh", zsh, parse_zsh),
        ("bash", vec![home.join(".bash_history")], parse_bash),
        ("fish", vec![xdg_data.join("fish/fish_history")], parse_fish),
    ];
    let mut records = Vec::new();
    let mut report = Vec::new();
    for (shell, candidates, parse) in sources {
        let Some((path, bytes, mtime)) = candidates.iter().find_map(|path| read(path)) else {
            continue;
        };
        let lines = parse(&bytes);
        let found = fold(&lines, mtime);
        report.push(Source {
            shell,
            path,
            commands: found.len(),
        });
        records.extend(found);
    }
    (records, report)
}

fn read(path: &Path) -> Option<(PathBuf, Vec<u8>, u64)> {
    let metadata = std::fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_FILE {
        return None;
    }
    let mtime = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since_epoch| since_epoch.as_secs());
    Some((path.to_owned(), std::fs::read(path).ok()?, mtime))
}

/// One record per distinct command: its count and last time (ms).
fn fold(lines: &[Line], mtime: u64) -> Vec<Record> {
    let total = lines.len() as u64;
    let mut per_command: HashMap<&str, (u32, u64)> = HashMap::new();
    let mut order: Vec<&str> = Vec::new();
    for (i, (command, when)) in lines.iter().enumerate() {
        let command = command.trim_end();
        if command.trim().is_empty() {
            continue;
        }
        let at_ms = when.unwrap_or_else(|| mtime.saturating_sub(total - i as u64)) * 1000;
        let slot = per_command.entry(command).or_insert_with(|| {
            order.push(command);
            (0, 0)
        });
        slot.0 += 1;
        slot.1 = slot.1.max(at_ms);
    }
    order
        .into_iter()
        .map(|command| {
            let (count, last_ms) = per_command[command];
            Record {
                c: command.to_owned(),
                d: None,
                x: None,
                ms: None,
                t: last_ms,
                n: count,
            }
        })
        .collect()
}

/// Undoes zsh's metafication: `0x83` marks the next byte as xor 32.
fn unmetafy(bytes: &[u8]) -> Vec<u8> {
    let mut unmetafied = Vec::with_capacity(bytes.len());
    let mut rest = bytes.iter();
    while let Some(&byte) = rest.next() {
        if byte == 0x83 {
            if let Some(&next) = rest.next() {
                unmetafied.push(next ^ 32);
            }
        } else {
            unmetafied.push(byte);
        }
    }
    unmetafied
}

pub(crate) fn parse_zsh(bytes: &[u8]) -> Vec<Line> {
    let text = String::from_utf8_lossy(&unmetafy(bytes)).into_owned();
    let mut parsed = Vec::new();
    let mut pending: Option<(String, Option<u64>)> = None;
    for line in text.split('\n') {
        let (body, when) = match &mut pending {
            Some((command, _)) => {
                command.push('\n');
                (line, None)
            }
            None => match extended(line) {
                Some((when, command)) => (command, Some(when)),
                None => (line, None),
            },
        };
        let (body, continues) = match body.strip_suffix('\\') {
            Some(stripped) => (stripped, true),
            None => (body, false),
        };
        let entry = pending.get_or_insert_with(|| (String::new(), when));
        entry.0.push_str(body);
        if !continues {
            parsed.extend(pending.take());
        }
    }
    parsed.extend(pending);
    parsed
}

/// `: 1700000000:0;cmd` → (1700000000, "cmd").
fn extended(line: &str) -> Option<(u64, &str)> {
    let rest = line.strip_prefix(": ")?;
    let (stamp, command) = rest.split_once(';')?;
    let (start, elapsed) = stamp.split_once(':')?;
    if !elapsed.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    Some((start.trim().parse().ok()?, command))
}

pub(crate) fn parse_bash(bytes: &[u8]) -> Vec<Line> {
    let text = String::from_utf8_lossy(bytes);
    let mut parsed = Vec::new();
    let mut when = None;
    for line in text.lines() {
        if let Some(stamp) = line.strip_prefix('#')
            && !stamp.is_empty()
            && stamp.bytes().all(|byte| byte.is_ascii_digit())
        {
            when = stamp.parse().ok();
            continue;
        }
        parsed.push((line.to_owned(), when.take()));
    }
    parsed
}

pub(crate) fn parse_fish(bytes: &[u8]) -> Vec<Line> {
    let text = String::from_utf8_lossy(bytes);
    let mut parsed: Vec<Line> = Vec::new();
    for line in text.lines() {
        if let Some(command) = line.strip_prefix("- cmd: ") {
            parsed.push((unescape_fish(command), None));
        } else if let Some(when) = line.trim_start().strip_prefix("when: ")
            && let Some(last) = parsed.last_mut()
        {
            last.1 = when.trim().parse().ok();
        }
    }
    parsed
}

fn unescape_fish(escaped: &str) -> String {
    let mut unescaped = String::with_capacity(escaped.len());
    let mut chars = escaped.chars();
    while let Some(character) = chars.next() {
        if character != '\\' {
            unescaped.push(character);
            continue;
        }
        match chars.next() {
            Some('n') => unescaped.push('\n'),
            Some('\\') => unescaped.push('\\'),
            Some(other) => {
                unescaped.push('\\');
                unescaped.push(other);
            }
            None => unescaped.push('\\'),
        }
    }
    unescaped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zsh_extended_multiline_and_metafied() {
        let mut bytes = b": 1700000000:0;git status\n: 1700000100:2;for i in 1 2\\\ndo echo $i\\\ndone\nls -la\n".to_vec();
        // "é" is 0xC3 0xA9; zsh metafies 0x83..0x9F and 0xA0+ bytes that clash with its tokens.
        bytes.extend_from_slice(b": 1700000200:0;echo caf\xc3\x83\x89\n");
        let lines = parse_zsh(&bytes);
        assert_eq!(lines[0], ("git status".into(), Some(1_700_000_000)));
        assert_eq!(lines[1].0, "for i in 1 2\ndo echo $i\ndone");
        assert_eq!(lines[1].1, Some(1_700_000_100));
        assert_eq!(lines[2], ("ls -la".into(), None));
        assert_eq!(lines[3].0, "echo café");
    }

    #[test]
    fn bash_with_and_without_timestamps() {
        let lines = parse_bash(b"ls\n#1700000000\nmake test\nmake test\n");
        assert_eq!(
            lines,
            vec![
                ("ls".into(), None),
                ("make test".into(), Some(1_700_000_000)),
                ("make test".into(), None),
            ]
        );
        let records = fold(&lines, 1_800_000_000);
        assert_eq!(records.len(), 2);
        let make = records
            .iter()
            .find(|record| record.c == "make test")
            .unwrap();
        assert_eq!(make.n, 2);
        // The untimestamped repeat is later than the stamped one.
        assert!(make.t > 1_700_000_000_000);
    }

    #[test]
    fn fish_entries() {
        let text = "- cmd: echo hello\\nworld\n  when: 1700000000\n  paths:\n    - world\n- cmd: cd \\\\tmp\n  when: 1700000005\n";
        let lines = parse_fish(text.as_bytes());
        assert_eq!(lines[0], ("echo hello\nworld".into(), Some(1_700_000_000)));
        assert_eq!(lines[1], ("cd \\tmp".into(), Some(1_700_000_005)));
    }

    #[test]
    fn imports_from_a_home() {
        let home = tempfile::tempdir().unwrap();
        std::fs::write(home.path().join(".zsh_history"), ": 1:0;zcmd\n").unwrap();
        std::fs::write(home.path().join(".bash_history"), "bcmd\nzcmd\n").unwrap();
        std::fs::create_dir_all(home.path().join(".local/share/fish")).unwrap();
        std::fs::write(
            home.path().join(".local/share/fish/fish_history"),
            "- cmd: fcmd\n  when: 2\n",
        )
        .unwrap();
        let (records, report) = import_all(home.path());
        assert_eq!(report.len(), 3, "{report:?}");
        let commands: Vec<_> = records.iter().map(|record| record.c.as_str()).collect();
        assert!(
            commands.contains(&"zcmd") && commands.contains(&"bcmd") && commands.contains(&"fcmd")
        );
    }
}
