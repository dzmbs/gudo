//! GitHub through the host's own `gh` CLI: the daemon never holds a token, it runs `gh` as
//! the user (who signed in with `gh auth login`, or set `GH_TOKEN`).
//!
//! Everything here blocks; callers run it on `spawn_blocking`. Every call has a timeout, so
//! a hung network never wedges the refresher.

use std::collections::BTreeSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use proto::{
    CheckStatus, GhStatus, MergeState, MergeStrategy, PrCheck, PrState, PullRequest, UnixMillis,
    WsError,
};
use serde::Deserialize;

const TIMEOUT: Duration = Duration::from_secs(30);
const LONG_TIMEOUT: Duration = Duration::from_secs(120);

pub(crate) const PR_FIELDS: &str = "number,title,state,isDraft,headRefName,additions,deletions,\
mergeStateStatus,statusCheckRollup,url";

/// Why `gh pr view` gave no pull request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ViewError {
    Missing,
    Auth(String),
    /// The repository has no GitHub remote: there will never be a pull request.
    NotGitHub,
    /// Anything else (network, rate limit); retried with back-off.
    Other(String),
}

/// Finds `gh`: the configured path, then `PATH`, then the usual install locations (a daemon
/// started by launchd or systemd has a short `PATH`).
pub(crate) fn find(configured: Option<&Path>) -> Option<PathBuf> {
    if let Some(path) = configured {
        return path.is_file().then(|| path.to_owned());
    }
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();
    let home = std::env::var_os("HOME").map(PathBuf::from);
    dirs.extend(
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/home/linuxbrew/.linuxbrew/bin",
            "/snap/bin",
        ]
        .map(PathBuf::from),
    );
    if let Some(home) = home {
        dirs.push(home.join(".local/bin"));
        dirs.push(home.join("bin"));
    }
    dirs.into_iter()
        .map(|dir| dir.join("gh"))
        .find(|candidate| candidate.is_file())
}

struct Output {
    ok: bool,
    stdout: Vec<u8>,
    stderr: String,
}

fn run(program: &Path, dir: &Path, args: &[&str], timeout: Duration) -> Result<Output, WsError> {
    let mut command = Command::new(program);
    command
        .current_dir(dir)
        .args(args)
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_SPINNER_DISABLED", "1")
        .env("NO_COLOR", "1")
        .env("CLICOLOR", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C");
    // The git `gh` runs gets the same guard as ours against the repository's own config.
    let guard = super::git::guard(dir, false);
    command.env("GIT_CONFIG_COUNT", guard.len().to_string());
    for (i, setting) in guard.iter().enumerate() {
        let (key, value) = setting.split_once('=').unwrap_or((setting, ""));
        command
            .env(format!("GIT_CONFIG_KEY_{i}"), key)
            .env(format!("GIT_CONFIG_VALUE_{i}"), value);
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                WsError::Unavailable(format!("{} is not installed", program.display()))
            } else {
                WsError::Failed(format!("running {}: {error}", program.display()))
            }
        })?;
    // Drain both pipes on threads so a chatty child never blocks on a full pipe.
    let mut stdout_pipe = child.stdout.take().expect("piped");
    let mut stderr_pipe = child.stderr.take().expect("piped");
    let stdout_reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout_pipe.read_to_end(&mut bytes);
        bytes
    });
    let stderr_reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stderr_pipe.read_to_end(&mut bytes);
        bytes
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(WsError::Failed(format!(
                    "{} {} timed out",
                    program.display(),
                    args.first().copied().unwrap_or_default()
                )));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(error) => return Err(WsError::Failed(error.to_string())),
        }
    };
    Ok(Output {
        ok: status.success(),
        stdout: stdout_reader.join().unwrap_or_default(),
        stderr: String::from_utf8_lossy(&stderr_reader.join().unwrap_or_default())
            .trim()
            .to_owned(),
    })
}

/// Whether `gh` is installed and signed in.
pub(crate) fn auth_status(gh: Option<&Path>) -> GhStatus {
    let Some(gh) = gh else {
        return GhStatus::Missing;
    };
    let home = std::env::var_os("HOME").map_or_else(|| PathBuf::from("/"), PathBuf::from);
    match run(gh, &home, &["auth", "status"], TIMEOUT) {
        Err(WsError::Unavailable(_)) => GhStatus::Missing,
        Err(error) => GhStatus::NotAuthenticated {
            message: error.to_string(),
        },
        Ok(output) => {
            let text = format!(
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                output.stderr
            );
            if output.ok {
                GhStatus::Ready {
                    account: account_of(&text),
                }
            } else {
                GhStatus::NotAuthenticated {
                    message: first_line(&text),
                }
            }
        }
    }
}

/// `Logged in to github.com account octo (keyring)` or the older `… as octo (…)`.
fn account_of(text: &str) -> Option<String> {
    text.lines().find_map(|line| {
        let line = line.trim().trim_start_matches(['✓', '-', ' ']);
        let rest = line.strip_prefix("Logged in to ")?;
        let after = rest
            .split_once(" account ")
            .or_else(|| rest.split_once(" as "))?
            .1;
        after.split_whitespace().next().map(str::to_owned)
    })
}

fn first_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("gh is not signed in")
        .to_owned()
}

/// The pull request of `branch`, if any (open first, else the latest merged or closed).
pub(crate) fn pr_view(
    gh: &Path,
    dir: &Path,
    branch: &str,
    now: UnixMillis,
) -> Result<Option<PullRequest>, ViewError> {
    if branch.starts_with('-') {
        return Ok(None);
    }
    let output = run(
        gh,
        dir,
        &["pr", "view", branch, "--json", PR_FIELDS],
        TIMEOUT,
    )
    .map_err(|error| match error {
        WsError::Unavailable(_) => ViewError::Missing,
        error => ViewError::Other(error.to_string()),
    })?;
    if !output.ok {
        return Err(classify(&output.stderr)).or_else(|error| match error {
            ViewError::Other(message) if message.is_empty() => Ok(None),
            error => Err(error),
        });
    }
    parse_pr(&output.stdout, now)
        .map(Some)
        .map_err(|error| ViewError::Other(format!("could not read gh's answer: {error}")))
}

fn classify(stderr: &str) -> ViewError {
    let lower = stderr.to_ascii_lowercase();
    if lower.contains("no pull requests found") || lower.contains("could not find pull request") {
        // Not an error: the branch has none.
        ViewError::Other(String::new())
    } else if lower.contains("gh auth login")
        || lower.contains("not logged in")
        || lower.contains("401")
    {
        ViewError::Auth(first_line(stderr))
    } else if lower.contains("none of the git remotes")
        || lower.contains("no git remotes")
        || lower.contains("not a git repository")
        || lower.contains("unable to determine base repository")
    {
        ViewError::NotGitHub
    } else {
        ViewError::Other(first_line(stderr))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPr {
    number: u32,
    #[serde(default)]
    title: String,
    #[serde(default)]
    state: String,
    #[serde(default)]
    is_draft: bool,
    #[serde(default)]
    head_ref_name: String,
    #[serde(default)]
    additions: u32,
    #[serde(default)]
    deletions: u32,
    #[serde(default)]
    merge_state_status: String,
    #[serde(default)]
    status_check_rollup: Vec<RawCheck>,
    #[serde(default)]
    url: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawCheck {
    #[serde(default, rename = "__typename")]
    typename: String,
    // CheckRun
    #[serde(default)]
    name: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    conclusion: String,
    #[serde(default)]
    details_url: Option<String>,
    #[serde(default)]
    workflow_name: Option<String>,
    // StatusContext
    #[serde(default)]
    context: String,
    #[serde(default)]
    state: String,
    #[serde(default)]
    target_url: Option<String>,
}

pub(crate) fn parse_pr(json: &[u8], now: UnixMillis) -> Result<PullRequest, serde_json::Error> {
    let raw: RawPr = serde_json::from_slice(json)?;
    let mut checks: Vec<PrCheck> = raw.status_check_rollup.into_iter().map(check).collect();
    // Failures first, then running, then the rest; by name within a group.
    checks.sort_by(|a, b| {
        rank(a.status)
            .cmp(&rank(b.status))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(PullRequest {
        number: raw.number,
        title: raw.title,
        state: match raw.state.as_str() {
            "MERGED" => PrState::Merged,
            "CLOSED" => PrState::Closed,
            _ => PrState::Open,
        },
        draft: raw.is_draft,
        url: raw.url,
        head_ref: raw.head_ref_name,
        additions: raw.additions,
        deletions: raw.deletions,
        merge_state: match raw.merge_state_status.as_str() {
            "CLEAN" => MergeState::Clean,
            "UNSTABLE" => MergeState::Unstable,
            "HAS_HOOKS" => MergeState::HasHooks,
            "BEHIND" => MergeState::Behind,
            "BLOCKED" => MergeState::Blocked,
            "DIRTY" => MergeState::Dirty,
            "DRAFT" => MergeState::Draft,
            _ => MergeState::Unknown,
        },
        checks,
        fetched_at: now,
    })
}

fn rank(status: CheckStatus) -> u8 {
    match status {
        CheckStatus::Failure => 0,
        CheckStatus::Pending => 1,
        CheckStatus::Cancelled => 2,
        CheckStatus::Skipped => 3,
        CheckStatus::Neutral => 4,
        CheckStatus::Success => 5,
    }
}

fn check(raw: RawCheck) -> PrCheck {
    if raw.typename == "StatusContext" || (!raw.context.is_empty() && raw.name.is_empty()) {
        return PrCheck {
            name: raw.context,
            status: match raw.state.as_str() {
                "SUCCESS" => CheckStatus::Success,
                "FAILURE" | "ERROR" => CheckStatus::Failure,
                _ => CheckStatus::Pending,
            },
            url: raw.target_url.filter(|url| !url.is_empty()),
            workflow: None,
        };
    }
    let status = if raw.status != "COMPLETED" && !raw.status.is_empty() {
        CheckStatus::Pending
    } else {
        match raw.conclusion.as_str() {
            "SUCCESS" => CheckStatus::Success,
            "NEUTRAL" => CheckStatus::Neutral,
            "SKIPPED" => CheckStatus::Skipped,
            "CANCELLED" => CheckStatus::Cancelled,
            "" => CheckStatus::Pending,
            // FAILURE, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE, STALE
            _ => CheckStatus::Failure,
        }
    };
    PrCheck {
        name: raw.name,
        status,
        url: raw.details_url.filter(|url| !url.is_empty()),
        workflow: raw.workflow_name.filter(|name| !name.is_empty()),
    }
}

fn require(output: Output, what: &str) -> Result<Output, WsError> {
    if output.ok {
        Ok(output)
    } else {
        let message = if output.stderr.is_empty() {
            String::from_utf8_lossy(&output.stdout).trim().to_owned()
        } else {
            output.stderr.clone()
        };
        let lower = message.to_ascii_lowercase();
        if lower.contains("gh auth login") {
            Err(WsError::Unavailable(format!(
                "gh is not signed in on the host; run `gh auth login` there ({message})"
            )))
        } else {
            Err(WsError::Failed(format!("{what}: {message}")))
        }
    }
}

/// `gh pr merge <number> --merge|--squash|--rebase`.
pub(crate) fn merge(
    gh: &Path,
    dir: &Path,
    number: u32,
    strategy: MergeStrategy,
) -> Result<(), WsError> {
    let flag = match strategy {
        MergeStrategy::Merge => "--merge",
        MergeStrategy::Squash => "--squash",
        MergeStrategy::Rebase => "--rebase",
    };
    let number = number.to_string();
    require(
        run(gh, dir, &["pr", "merge", &number, flag], LONG_TIMEOUT)?,
        "gh pr merge",
    )
    .map(drop)
}

/// The Actions run ids of failed checks (`…/actions/runs/<id>/job/<job>`).
pub(crate) fn failed_runs(pr: &PullRequest) -> BTreeSet<u64> {
    pr.checks
        .iter()
        .filter(|check| check.status == CheckStatus::Failure)
        .filter_map(|check| check.url.as_deref())
        .filter_map(|url| {
            let rest = url.split("/actions/runs/").nth(1)?;
            rest.split(['/', '?', '#']).next()?.parse().ok()
        })
        .collect()
}

/// `gh run rerun <id> --failed` for each run.
pub(crate) fn rerun_failed(gh: &Path, dir: &Path, runs: &BTreeSet<u64>) -> Result<(), WsError> {
    for id in runs {
        let id = id.to_string();
        require(
            run(gh, dir, &["run", "rerun", &id, "--failed"], TIMEOUT)?,
            "gh run rerun",
        )?;
    }
    Ok(())
}

/// `gh pr create --fill [--draft] [--base B]` (the branch must be pushed).
pub(crate) fn create(
    gh: &Path,
    dir: &Path,
    draft: bool,
    base: Option<&str>,
) -> Result<(), WsError> {
    let mut args = vec!["pr", "create", "--fill"];
    if draft {
        args.push("--draft");
    }
    if let Some(base) = base {
        if base.starts_with('-') {
            return Err(WsError::Invalid(format!("bad base {base:?}")));
        }
        args.extend(["--base", base]);
    }
    require(run(gh, dir, &args, LONG_TIMEOUT)?, "gh pr create").map(drop)
}

/// `gh pr checkout <number> [--branch B]` in `dir`.
pub(crate) fn checkout(
    gh: &Path,
    dir: &Path,
    number: u32,
    branch: Option<&str>,
) -> Result<(), WsError> {
    let number = number.to_string();
    let mut args = vec!["pr", "checkout", number.as_str()];
    if let Some(branch) = branch {
        args.extend(["--branch", branch]);
    }
    require(run(gh, dir, &args, LONG_TIMEOUT)?, "gh pr checkout").map(drop)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `gh` runs git in the repository (status, checkout): the repository's own filters and
    /// fsmonitor must not run through it either.
    #[test]
    fn the_git_gh_runs_is_guarded_too() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        let marker = dir.path().join("ran");
        let git = |args: &[&str]| {
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
        let script = |name: &str, body: &str| {
            let path = dir.path().join(name);
            std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            path
        };
        let evil = script(
            "evil",
            &format!("echo \"$0\" >> '{}'; cat", marker.display()),
        );
        std::fs::create_dir(&repo).unwrap();
        git(&["init", "-q"]);
        git(&["config", "user.email", "t@t"]);
        git(&["config", "user.name", "t"]);
        std::fs::write(repo.join(".gitattributes"), "* filter=x\n").unwrap();
        std::fs::write(repo.join("a.txt"), "one\n").unwrap();
        git(&["add", "."]);
        git(&["commit", "-qm", "one"]);
        git(&["config", "filter.x.clean", &evil.to_string_lossy()]);
        git(&["config", "filter.x.smudge", &evil.to_string_lossy()]);
        git(&["config", "core.fsmonitor", &evil.to_string_lossy()]);
        std::fs::write(repo.join("a.txt"), "two\n").unwrap();
        // Stands in for `gh`, doing what `gh pr status` and `gh pr checkout` do.
        let gh = script(
            "gh",
            "git status --porcelain >/dev/null && git checkout -q -- . && git status >/dev/null",
        );
        run(&gh, &repo, &[], TIMEOUT).unwrap();
        let ran = std::fs::read_to_string(&marker).unwrap_or_default();
        assert!(ran.is_empty(), "ran: {ran}");
    }

    #[test]
    fn parses_a_pr_with_checks() {
        let json = br#"{"number":7,"title":"Add x","state":"OPEN","isDraft":false,
            "headRefName":"feat","additions":12,"deletions":3,"mergeStateStatus":"UNSTABLE",
            "url":"https://github.com/o/r/pull/7","statusCheckRollup":[
            {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS",
             "detailsUrl":"https://github.com/o/r/actions/runs/11/job/1","workflowName":"CI"},
            {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"TIMED_OUT",
             "detailsUrl":"https://github.com/o/r/actions/runs/12/job/2","workflowName":"CI"},
            {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":""},
            {"__typename":"StatusContext","context":"deploy","state":"ERROR","targetUrl":"x"}]}"#;
        let pr = parse_pr(json, UnixMillis(1)).unwrap();
        assert_eq!(pr.number, 7);
        assert_eq!(pr.merge_state, MergeState::Unstable);
        let names: Vec<_> = pr.checks.iter().map(|check| check.name.as_str()).collect();
        assert_eq!(names, ["deploy", "test", "lint", "build"]);
        assert_eq!(pr.checks[2].status, CheckStatus::Pending);
        assert_eq!(failed_runs(&pr), BTreeSet::from([12]));
    }

    #[test]
    fn reads_the_account() {
        assert_eq!(
            account_of("github.com\n  ✓ Logged in to github.com account octo (keyring)\n"),
            Some("octo".into())
        );
        assert_eq!(
            account_of("✓ Logged in to github.com as hubot (oauth_token)"),
            Some("hubot".into())
        );
    }

    #[test]
    fn classifies_errors() {
        assert_eq!(
            classify("no pull requests found for branch \"x\""),
            ViewError::Other(String::new())
        );
        assert_eq!(
            classify(
                "none of the git remotes configured for this repository point to a known GitHub host"
            ),
            ViewError::NotGitHub
        );
        assert!(matches!(
            classify("To get started with GitHub CLI, please run:  gh auth login"),
            ViewError::Auth(_)
        ));
    }
}
