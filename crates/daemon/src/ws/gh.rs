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

/// `gh pr view` and friends get this long.
const TIMEOUT: Duration = Duration::from_secs(30);
/// Pushing and creating a pull request may take longer.
const LONG_TIMEOUT: Duration = Duration::from_secs(120);

/// The fields asked of `gh pr view --json`.
pub(crate) const PR_FIELDS: &str = "number,title,state,isDraft,headRefName,additions,deletions,\
mergeStateStatus,statusCheckRollup,url";

/// Why `gh pr view` gave no pull request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ViewError {
    /// `gh` is not installed.
    Missing,
    /// `gh` is not signed in.
    Auth(String),
    /// The repository has no GitHub remote: there will never be a pull request.
    NotGitHub,
    /// Anything else (network, rate limit); retried with back-off.
    Other(String),
}

/// Finds `gh`: the configured path, then `PATH`, then the usual install locations (a daemon
/// started by launchd or systemd has a short `PATH`).
pub(crate) fn find(configured: Option<&Path>) -> Option<PathBuf> {
    if let Some(p) = configured {
        return p.is_file().then(|| p.to_owned());
    }
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
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
    dirs.into_iter().map(|d| d.join("gh")).find(|p| p.is_file())
}

struct Output {
    ok: bool,
    stdout: Vec<u8>,
    stderr: String,
}

/// Runs `program args` in `dir` with a timeout.
fn run(program: &Path, dir: &Path, args: &[&str], timeout: Duration) -> Result<Output, WsError> {
    let mut child = Command::new(program)
        .current_dir(dir)
        .args(args)
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_SPINNER_DISABLED", "1")
        .env("NO_COLOR", "1")
        .env("CLICOLOR", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                WsError::Unavailable(format!("{} is not installed", program.display()))
            } else {
                WsError::Failed(format!("running {}: {e}", program.display()))
            }
        })?;
    // Drain both pipes on threads so a chatty child never blocks on a full pipe.
    let mut out = child.stdout.take().expect("piped");
    let mut err = child.stderr.take().expect("piped");
    let out_t = std::thread::spawn(move || {
        let mut v = Vec::new();
        let _ = out.read_to_end(&mut v);
        v
    });
    let err_t = std::thread::spawn(move || {
        let mut v = Vec::new();
        let _ = err.read_to_end(&mut v);
        v
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
            Err(e) => return Err(WsError::Failed(e.to_string())),
        }
    };
    Ok(Output {
        ok: status.success(),
        stdout: out_t.join().unwrap_or_default(),
        stderr: String::from_utf8_lossy(&err_t.join().unwrap_or_default())
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
        Err(e) => GhStatus::NotAuthenticated {
            message: e.to_string(),
        },
        Ok(out) => {
            let text = format!("{}\n{}", String::from_utf8_lossy(&out.stdout), out.stderr);
            if out.ok {
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
        .find(|l| !l.is_empty())
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
    let out = run(
        gh,
        dir,
        &["pr", "view", branch, "--json", PR_FIELDS],
        TIMEOUT,
    )
    .map_err(|e| match e {
        WsError::Unavailable(_) => ViewError::Missing,
        e => ViewError::Other(e.to_string()),
    })?;
    if !out.ok {
        return Err(classify(&out.stderr)).or_else(|e| match e {
            ViewError::Other(m) if m.is_empty() => Ok(None),
            e => Err(e),
        });
    }
    parse_pr(&out.stdout, now)
        .map(Some)
        .map_err(|e| ViewError::Other(format!("could not read gh's answer: {e}")))
}

fn classify(stderr: &str) -> ViewError {
    let s = stderr.to_ascii_lowercase();
    if s.contains("no pull requests found") || s.contains("could not find pull request") {
        // Not an error: the branch has none.
        ViewError::Other(String::new())
    } else if s.contains("gh auth login") || s.contains("not logged in") || s.contains("401") {
        ViewError::Auth(first_line(stderr))
    } else if s.contains("none of the git remotes")
        || s.contains("no git remotes")
        || s.contains("not a git repository")
        || s.contains("unable to determine base repository")
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

fn rank(s: CheckStatus) -> u8 {
    match s {
        CheckStatus::Failure => 0,
        CheckStatus::Pending => 1,
        CheckStatus::Cancelled => 2,
        CheckStatus::Skipped => 3,
        CheckStatus::Neutral => 4,
        CheckStatus::Success => 5,
    }
}

fn check(c: RawCheck) -> PrCheck {
    if c.typename == "StatusContext" || (!c.context.is_empty() && c.name.is_empty()) {
        return PrCheck {
            name: c.context,
            status: match c.state.as_str() {
                "SUCCESS" => CheckStatus::Success,
                "FAILURE" | "ERROR" => CheckStatus::Failure,
                _ => CheckStatus::Pending,
            },
            url: c.target_url.filter(|u| !u.is_empty()),
            workflow: None,
        };
    }
    let status = if c.status != "COMPLETED" && !c.status.is_empty() {
        CheckStatus::Pending
    } else {
        match c.conclusion.as_str() {
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
        name: c.name,
        status,
        url: c.details_url.filter(|u| !u.is_empty()),
        workflow: c.workflow_name.filter(|w| !w.is_empty()),
    }
}

fn require(out: Output, what: &str) -> Result<Output, WsError> {
    if out.ok {
        Ok(out)
    } else {
        let msg = if out.stderr.is_empty() {
            String::from_utf8_lossy(&out.stdout).trim().to_owned()
        } else {
            out.stderr.clone()
        };
        let lower = msg.to_ascii_lowercase();
        if lower.contains("gh auth login") {
            Err(WsError::Unavailable(format!(
                "gh is not signed in on the host; run `gh auth login` there ({msg})"
            )))
        } else {
            Err(WsError::Failed(format!("{what}: {msg}")))
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
    let n = number.to_string();
    require(
        run(gh, dir, &["pr", "merge", &n, flag], LONG_TIMEOUT)?,
        "gh pr merge",
    )
    .map(drop)
}

/// The Actions run ids of failed checks (`…/actions/runs/<id>/job/<job>`).
pub(crate) fn failed_runs(pr: &PullRequest) -> BTreeSet<u64> {
    pr.checks
        .iter()
        .filter(|c| c.status == CheckStatus::Failure)
        .filter_map(|c| c.url.as_deref())
        .filter_map(|u| {
            let rest = u.split("/actions/runs/").nth(1)?;
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
    let n = number.to_string();
    let mut args = vec!["pr", "checkout", n.as_str()];
    if let Some(b) = branch {
        args.extend(["--branch", b]);
    }
    require(run(gh, dir, &args, LONG_TIMEOUT)?, "gh pr checkout").map(drop)
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let names: Vec<_> = pr.checks.iter().map(|c| c.name.as_str()).collect();
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
