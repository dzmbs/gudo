//! Agents started by hand in a shell pane that the daemon does not drive but can resume after
//! a restart: pi and Kimi Code. The pane comes back running the agent's own resume command in
//! its directory, then the shell. Each one's resume was checked against its CLI.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Deserializer, Serialize};

use crate::core::shell_quote;

/// An agent this module knows how to resume.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) enum ResumableProgram {
    /// pi: sessions in `$PI_CODING_AGENT_DIR/sessions/--<cwd>--/<time>_<id>.jsonl`.
    Pi,
    /// Kimi Code: sessions in `$KIMI_CODE_HOME/sessions/wd_<name>_<sha256>/session_<id>/`.
    Kimi,
}

/// The agent a pane ran, and its session once known.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ResumableAgent {
    pub program: ResumableProgram,
    pub session_id: Option<String>,
    /// The agent's own working directory, where it resumes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
}

/// Reads a saved agent, as `None` when it names one this build does not know: a newer
/// daemon's `layout.json` must still load.
pub(crate) fn lenient<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<ResumableAgent>, D::Error> {
    let value = serde_json::Value::deserialize(deserializer)?;
    Ok(serde_json::from_value(value).ok())
}

/// Slack for an agent that wrote its session a moment before the pane noticed it.
const NOTICED_LATE: Duration = Duration::from_secs(5);

impl ResumableProgram {
    /// The resumable agent `process` runs, also under a script runtime.
    pub fn of(process: &pty::ForegroundProcess) -> Option<Self> {
        match process.program() {
            "pi" => Some(Self::Pi),
            "kimi" => Some(Self::Kimi),
            "node" | "bun" => process
                .argv
                .iter()
                .any(|arg| arg.contains("/pi-coding-agent/"))
                .then_some(Self::Pi),
            _ => None,
        }
    }

    fn executable(self) -> &'static str {
        match self {
            Self::Pi => "pi",
            Self::Kimi => "kimi",
        }
    }

    /// The session named on the command line, if any.
    pub fn session_from_argv(self, argv: &[String]) -> Option<String> {
        let flags: &[&str] = match self {
            Self::Pi => &["--session", "--session-id"],
            Self::Kimi => &["--session", "-S", "-r"],
        };
        argv.iter()
            .enumerate()
            .find_map(|(i, arg)| {
                if flags.contains(&arg.as_str()) {
                    return argv.get(i + 1).cloned();
                }
                flags
                    .iter()
                    .find_map(|flag| arg.strip_prefix(flag)?.strip_prefix('=').map(str::to_owned))
            })
            .filter(|id| is_session_id(id))
    }

    /// The shell line that starts the agent fresh, or in `session_id`.
    pub fn launch_line(self, session_id: Option<&str>) -> String {
        match session_id.filter(|id| is_session_id(id)) {
            Some(id) => format!("{} --session {}", self.executable(), shell_quote(id)),
            None => self.executable().to_owned(),
        }
    }

    /// The shell line that resumes `session_id`, or the newest session in the directory.
    /// Nothing else from the first run comes back: a prompt in its arguments would be sent
    /// again.
    pub fn resume_line(self, session_id: Option<&str>) -> String {
        let flags = match session_id.filter(|id| is_session_id(id)) {
            Some(id) => format!("--session {}", shell_quote(id)),
            None => "--continue".to_owned(),
        };
        format!("{} {flags}", self.executable())
    }

    /// The session an agent started at `started` in `cwd` writes: the newest one there written
    /// since then that no other pane claimed. `env` reads the pane's environment.
    pub fn find_session(
        self,
        env: impl Fn(&str) -> Option<String>,
        cwd: &Path,
        started: SystemTime,
        claimed: &[String],
    ) -> Option<String> {
        let since = started.checked_sub(NOTICED_LATE).unwrap_or(started);
        let home = env("HOME").map(PathBuf::from)?;
        let directories = [cwd.canonicalize().ok(), Some(cwd.to_path_buf())];
        directories.into_iter().flatten().find_map(|cwd| {
            let sessions = match self {
                Self::Pi => pi_sessions(&env, &home, &cwd),
                Self::Kimi => kimi_sessions(&env, &home, &cwd),
            };
            sessions
                .into_iter()
                .filter(|(_, modified)| *modified >= since)
                .filter(|(id, _)| !claimed.contains(id))
                .max_by_key(|(_, modified)| *modified)
                .map(|(id, _)| id)
        })
    }
}

/// Whether the agent saved session `id` where its resume looks from `cwd`: `None` when its
/// sessions folder is not there at all, so where it keeps them is unknown.
pub(crate) fn saved_session(
    program: ResumableProgram,
    env: &impl Fn(&str) -> Option<String>,
    home: &Path,
    cwd: &Path,
    id: &str,
) -> Option<bool> {
    let directories = [cwd.canonicalize().ok(), Some(cwd.to_path_buf())];
    match program {
        ResumableProgram::Pi => {
            let root = pi_session_dir(env, home, cwd).root;
            root.is_dir().then(|| {
                directories.iter().flatten().any(|cwd| {
                    pi_session_file(&pi_session_dir(env, home, cwd).folder, id).is_some()
                })
            })
        }
        ResumableProgram::Kimi => {
            let root = kimi_home(env, home).join("sessions");
            root.is_dir().then(|| {
                directories
                    .iter()
                    .flatten()
                    .any(|cwd| kimi_session_dir(env, home, cwd).join(id).is_dir())
            })
        }
    }
}

/// pi's sessions for `cwd`: (id, last written).
fn pi_sessions(
    env: &impl Fn(&str) -> Option<String>,
    home: &Path,
    cwd: &Path,
) -> Vec<(String, SystemTime)> {
    entries(&pi_session_dir(env, home, cwd).folder)
        .filter_map(|(path, modified)| {
            let name = path.file_name()?.to_str()?.strip_suffix(".jsonl")?;
            let (_, id) = name.split_once('_')?;
            is_session_id(id).then(|| (id.to_owned(), modified))
        })
        .collect()
}

/// Where pi keeps its sessions for one working directory.
pub(crate) struct PiSessionDir {
    /// The folder every pi session lives under: no session file is read outside it.
    pub root: PathBuf,
    pub folder: PathBuf,
}

/// pi's session folder for `cwd`, as pi chooses it.
pub(crate) fn pi_session_dir(
    env: &impl Fn(&str) -> Option<String>,
    home: &Path,
    cwd: &Path,
) -> PiSessionDir {
    if let Some(directory) = env("PI_CODING_AGENT_SESSION_DIR") {
        let folder = PathBuf::from(directory);
        return PiSessionDir {
            root: folder.clone(),
            folder,
        };
    }
    let agent_dir = env(agents::PI_DIR_VAR).map_or_else(|| home.join(".pi/agent"), PathBuf::from);
    let cwd = cwd.to_string_lossy();
    let encoded = cwd
        .trim_start_matches(['/', '\\'])
        .replace(['/', '\\', ':'], "-");
    let root = agent_dir.join("sessions");
    PiSessionDir {
        folder: root.join(format!("--{encoded}--")),
        root,
    }
}

/// The file of pi session `id` in `folder`.
pub(crate) fn pi_session_file(folder: &Path, id: &str) -> Option<PathBuf> {
    if !is_session_id(id) {
        return None;
    }
    let suffix = format!("_{id}.jsonl");
    entries(folder).map(|(path, _)| path).find(|path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(&suffix))
    })
}

/// Kimi Code's sessions for `cwd`: (id, last written).
fn kimi_sessions(
    env: &impl Fn(&str) -> Option<String>,
    home: &Path,
    cwd: &Path,
) -> Vec<(String, SystemTime)> {
    entries(&kimi_session_dir(env, home, cwd))
        .filter_map(|(path, modified)| {
            let id = path.file_name()?.to_str()?;
            let modified = std::fs::metadata(path.join("state.json"))
                .and_then(|metadata| metadata.modified())
                .unwrap_or(modified);
            (id.starts_with("session_") && is_session_id(id)).then(|| (id.to_owned(), modified))
        })
        .collect()
}

fn kimi_home(env: &impl Fn(&str) -> Option<String>, home: &Path) -> PathBuf {
    env("KIMI_CODE_HOME").map_or_else(|| home.join(".kimi-code"), PathBuf::from)
}

/// Kimi Code's session folder for `cwd`.
fn kimi_session_dir(env: &impl Fn(&str) -> Option<String>, home: &Path, cwd: &Path) -> PathBuf {
    let name = cwd
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let digest = ring::digest::digest(&ring::digest::SHA256, cwd.as_os_str().as_encoded_bytes());
    let hash = crate::fsutil::hex(&digest.as_ref()[..6]);
    kimi_home(env, home)
        .join("sessions")
        .join(format!("wd_{name}_{hash}"))
}

fn entries(directory: &Path) -> impl Iterator<Item = (PathBuf, SystemTime)> {
    std::fs::read_dir(directory)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| Some((entry.path(), entry.metadata().ok()?.modified().ok()?)))
}

/// Whether `id` may name an agent's session: ids come from file names, command lines and hook
/// payloads that any program could have written, and go back as an argument of the agent's
/// resume command, so one that starts with `-` would be read as an option.
pub(crate) fn is_session_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && !id.starts_with('-')
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(argv: &[&str]) -> pty::ForegroundProcess {
        pty::ForegroundProcess {
            pid: 1,
            name: "node".into(),
            argv: argv.iter().map(|arg| (*arg).to_owned()).collect(),
        }
    }

    #[test]
    fn agents_are_known_by_their_program() {
        assert_eq!(
            ResumableProgram::of(&process(&["pi"])),
            Some(ResumableProgram::Pi)
        );
        assert_eq!(
            ResumableProgram::of(&process(&[
                "node",
                "/opt/lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
            ])),
            Some(ResumableProgram::Pi)
        );
        assert_eq!(
            ResumableProgram::of(&process(&["/Users/someone/.kimi-code/bin/kimi", "-c"])),
            Some(ResumableProgram::Kimi)
        );
        assert_eq!(ResumableProgram::of(&process(&["vim"])), None);
    }

    #[test]
    fn resume_runs_the_session_or_the_newest_one() {
        assert_eq!(
            ResumableProgram::Pi.resume_line(Some("01a1")),
            "pi --session 01a1"
        );
        assert_eq!(ResumableProgram::Pi.resume_line(None), "pi --continue");
        assert_eq!(
            ResumableProgram::Kimi.resume_line(Some("session_b74e")),
            "kimi --session session_b74e"
        );
        assert_eq!(ResumableProgram::Kimi.resume_line(None), "kimi --continue");
    }

    #[test]
    fn a_session_on_the_command_line_is_used() {
        let argv = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
        let pi = ResumableProgram::Pi;
        assert_eq!(
            pi.session_from_argv(&argv(&["pi", "--session", "abc"])),
            Some("abc".into())
        );
        assert_eq!(
            pi.session_from_argv(&argv(&["pi", "--session-id=def"])),
            Some("def".into())
        );
        assert_eq!(pi.session_from_argv(&argv(&["pi", "fix the bug"])), None);
        for flag_shaped in [
            &["pi", "--session=--dangerously-skip-permissions"][..],
            &["pi", "--session", "--model"],
            &["pi", "--session=a b"],
        ] {
            assert_eq!(pi.session_from_argv(&argv(flag_shaped)), None);
        }
        assert_eq!(
            pi.resume_line(Some("--dangerously-skip-permissions")),
            "pi --continue"
        );
        assert_eq!(
            ResumableProgram::Kimi.session_from_argv(&argv(&["kimi", "-S", "session_1"])),
            Some("session_1".into())
        );
    }

    #[test]
    fn the_newest_session_in_the_directory_is_found() {
        let home = tempfile::tempdir().unwrap();
        let work = home.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        let work = work.canonicalize().unwrap();
        let env = |name: &str| (name == "HOME").then(|| home.path().display().to_string());
        let started = SystemTime::now();

        let encoded = work
            .to_string_lossy()
            .trim_start_matches('/')
            .replace('/', "-");
        let pi_dir = home
            .path()
            .join(format!(".pi/agent/sessions/--{encoded}--"));
        std::fs::create_dir_all(&pi_dir).unwrap();
        std::fs::write(
            pi_dir.join("2026-11-08T10-00-00-000Z_0199-aaaa.jsonl"),
            "{}",
        )
        .unwrap();
        assert_eq!(
            ResumableProgram::Pi.find_session(env, &work, started, &[]),
            Some("0199-aaaa".into())
        );
        assert_eq!(
            ResumableProgram::Pi.find_session(env, &work, started, &["0199-aaaa".into()]),
            None
        );

        let digest =
            ring::digest::digest(&ring::digest::SHA256, work.as_os_str().as_encoded_bytes());
        let kimi_dir = home.path().join(format!(
            ".kimi-code/sessions/wd_work_{}/session_1234",
            crate::fsutil::hex(&digest.as_ref()[..6])
        ));
        std::fs::create_dir_all(&kimi_dir).unwrap();
        std::fs::write(kimi_dir.join("state.json"), "{}").unwrap();
        assert_eq!(
            ResumableProgram::Kimi.find_session(env, &work, started, &[]),
            Some("session_1234".into())
        );
    }

    #[test]
    fn a_pi_session_is_saved_only_with_its_file() {
        let home = tempfile::tempdir().unwrap();
        let work = home.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        let env = |name: &str| (name == "HOME").then(|| home.path().display().to_string());
        let pi = ResumableProgram::Pi;
        assert_eq!(
            saved_session(pi, &env, home.path(), &work, "0199-aaaa"),
            None,
            "no sessions folder: pi may keep them elsewhere"
        );
        let folder = pi_session_dir(&env, home.path(), &work.canonicalize().unwrap()).folder;
        std::fs::create_dir_all(&folder).unwrap();
        assert_eq!(
            saved_session(pi, &env, home.path(), &work, "0199-aaaa"),
            Some(false)
        );
        std::fs::write(
            folder.join("2026-11-25T10-00-00-000Z_0199-aaaa.jsonl"),
            "{}",
        )
        .unwrap();
        assert_eq!(
            saved_session(pi, &env, home.path(), &work, "0199-aaaa"),
            Some(true)
        );
    }

    #[test]
    fn an_unknown_agent_in_a_saved_record_reads_as_none() {
        #[derive(Deserialize)]
        struct Record {
            #[serde(default, deserialize_with = "lenient")]
            resumable: Option<ResumableAgent>,
        }
        let known: Record =
            serde_json::from_str(r#"{"resumable":{"program":"pi","session_id":"x"}}"#).unwrap();
        assert_eq!(known.resumable.unwrap().program, ResumableProgram::Pi);
        let unknown: Record =
            serde_json::from_str(r#"{"resumable":{"program":"later","session_id":null}}"#).unwrap();
        assert!(unknown.resumable.is_none());
    }
}
