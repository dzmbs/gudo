//! Updating a running helper that refuses to hand its sessions over: 0.1.5 and 0.1.6 refuse
//! while an agent has live Chat. Rather than leave the user on that build, the helper is
//! stopped the usual way (it saves the layout, screens and agent sessions) and the build now at
//! its path is started, which resumes every agent in its pane. A launchd job or systemd unit
//! that starts another build is pointed at that build first, so what starts is what was checked.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

/// What those builds answer a restart or an upgrade while an agent has live Chat.
pub const REFUSED_FOR_LIVE_CHAT: &str = "Live agent Chat cannot survive a helper restart yet.";

const STOP_WAIT: Duration = Duration::from_secs(30);
const START_WAIT: Duration = Duration::from_secs(60);
const POLL: Duration = Duration::from_millis(100);

/// The service managers' tools; tests put fakes in their place.
#[derive(Debug, Clone)]
struct ServiceTools {
    launchctl: PathBuf,
    systemctl: PathBuf,
}

impl Default for ServiceTools {
    fn default() -> Self {
        Self {
            launchctl: PathBuf::from("launchctl"),
            systemctl: PathBuf::from("systemctl"),
        }
    }
}

/// A launchd job or systemd user unit: its name, the file that defines it and the program it
/// starts.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Job {
    name: String,
    definition: PathBuf,
    program: PathBuf,
}

impl Job {
    fn starts(&self, exe: &Path) -> bool {
        self.program
            .canonicalize()
            .is_ok_and(|program| program == exe)
    }
}

/// What keeps the helper running, and so starts it again.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Supervisor {
    Launchd(Job),
    Systemd(Job),
    /// Nothing: a helper started by hand or by a test, started again here with its command
    /// line and environment (its panes' `PATH` and homes come from it).
    None {
        arguments: Vec<OsString>,
        environment: Option<Vec<String>>,
    },
}

impl Supervisor {
    // A helper started from a terminal inherits that terminal's launchd label or systemd
    // invocation, so each is trusted only when the job or unit really is this helper.
    fn of(pid: u32, tools: &ServiceTools) -> Result<Self> {
        if let Some(label) = daemon::process_env_var(pid, "XPC_SERVICE_NAME")
            && let Some(job) = launchd_job(&label, pid, tools)?
        {
            return Ok(Self::Launchd(job));
        }
        if runs_in_systemd_unit(pid) {
            return systemd_job(tools).map(Self::Systemd);
        }
        let arguments = daemon::process_arguments(pid)
            .filter(|arguments| !arguments.is_empty())
            .context("reading the running helper's command line")?;
        Ok(Self::None {
            arguments,
            environment: daemon::process_environment(pid),
        })
    }

    /// The build it starts once the helper stops.
    fn program(&self) -> Option<&Path> {
        match self {
            Self::Launchd(job) | Self::Systemd(job) => Some(&job.program),
            Self::None { .. } => None,
        }
    }
}

fn gui_domain() -> String {
    format!("gui/{}", rustix::process::getuid().as_raw())
}

/// The launchd job `label`, when it is the one running the helper `pid`.
fn launchd_job(label: &str, pid: u32, tools: &ServiceTools) -> Result<Option<Job>> {
    if label.is_empty() || label == "0" || !cfg!(target_os = "macos") {
        return Ok(None);
    }
    let Ok(output) = Command::new(&tools.launchctl)
        .args(["print", &format!("{}/{label}", gui_domain())])
        .stderr(Stdio::null())
        .output()
    else {
        return Ok(None);
    };
    parse_launchd_job(label, pid, &String::from_utf8_lossy(&output.stdout))
}

/// Reads `launchctl print` of the job `label`: the job, when it runs the helper `pid`.
fn parse_launchd_job(label: &str, pid: u32, printed: &str) -> Result<Option<Job>> {
    let lines: Vec<&str> = printed.lines().map(str::trim).collect();
    if !lines.contains(&format!("pid = {pid}").as_str()) {
        return Ok(None);
    }
    let value = |key: &str| {
        lines
            .iter()
            .find_map(|line| line.strip_prefix(key))
            .map(PathBuf::from)
            .with_context(|| format!("launchd does not say what {label} starts"))
    };
    Ok(Some(Job {
        name: label.to_owned(),
        definition: value("path = ")?,
        program: value("program = ")?,
    }))
}

fn runs_in_systemd_unit(pid: u32) -> bool {
    let unit = format!("/{}.service", brand::DAEMON_BIN);
    std::fs::read_to_string(format!("/proc/{pid}/cgroup")).is_ok_and(|groups| {
        groups
            .lines()
            .any(|group| group.trim_end().ends_with(&unit))
    })
}

fn systemd_job(tools: &ServiceTools) -> Result<Job> {
    let unit = format!("{}.service", brand::DAEMON_BIN);
    let output = Command::new(&tools.systemctl)
        .args([
            "--user",
            "show",
            "--property=FragmentPath",
            "--property=ExecStart",
        ])
        .arg(&unit)
        .output()
        .context("running systemctl")?;
    parse_systemd_job(&unit, &String::from_utf8_lossy(&output.stdout))
}

/// Reads `systemctl show --property=FragmentPath --property=ExecStart` of `unit`.
fn parse_systemd_job(unit: &str, shown: &str) -> Result<Job> {
    let value = |key: &str| shown.lines().find_map(|line| line.strip_prefix(key));
    let program = value("ExecStart=").and_then(|command| {
        command
            .split(" ; ")
            .find_map(|field| field.trim_start_matches('{').trim().strip_prefix("path="))
    });
    let (Some(definition), Some(program)) = (value("FragmentPath="), program) else {
        bail!("systemd does not say what {unit} starts");
    };
    Ok(Job {
        name: unit.to_owned(),
        definition: PathBuf::from(definition.trim()),
        program: PathBuf::from(program.trim()),
    })
}

/// Stops the helper `pid` (serving `state_dir`, started at `started_at`), lets what supervises
/// it start the build at `into` (else the one it starts anyway) in its place, and waits until
/// that build serves. Returns the build it started.
pub fn restart(
    state_dir: &Path,
    pid: u32,
    started_at: u64,
    into: Option<&Path>,
) -> Result<PathBuf> {
    let tools = ServiceTools::default();
    let supervisor = Supervisor::of(pid, &tools)?;
    let exe = into
        .or_else(|| supervisor.program())
        .map(Path::to_path_buf)
        .or_else(|| executable_of(pid))
        .or_else(|| std::env::current_exe().ok())
        .context("finding the installed build")?;
    let exe = exe
        .canonicalize()
        .with_context(|| format!("finding {}", exe.display()))?;
    check_target(&exe)?;
    hand_over(&supervisor, &exe, state_dir, pid, &tools)?;
    wait_for_start(state_dir, started_at)?;
    Ok(exe)
}

/// Stops the helper `pid` and has `supervisor` start `exe` in its place. A job that starts
/// another build is pointed at `exe` first, so the build that starts is the one checked.
fn hand_over(
    supervisor: &Supervisor,
    exe: &Path,
    state_dir: &Path,
    pid: u32,
    tools: &ServiceTools,
) -> Result<()> {
    match supervisor {
        Supervisor::Launchd(job) => {
            let target = format!("{}/{}", gui_domain(), job.name);
            if job.starts(exe) {
                return run(Command::new(&tools.launchctl).args(["kickstart", "-k", &target]));
            }
            crate::service::repoint_launch_agent(&job.definition, &job.name, exe, state_dir)?;
            // A loaded job keeps the program it was loaded with until it is loaded again.
            run(Command::new(&tools.launchctl).args(["bootout", &target]))?;
            wait_until_stopped(pid, state_dir)?;
            run(Command::new(&tools.launchctl)
                .args(["bootstrap", &gui_domain()])
                .arg(&job.definition))
        }
        Supervisor::Systemd(job) => {
            if !job.starts(exe) {
                crate::service::repoint_systemd_unit(&job.definition, exe, state_dir)?;
                run(Command::new(&tools.systemctl).args(["--user", "daemon-reload"]))?;
            }
            run(Command::new(&tools.systemctl).args(["--user", "restart", &job.name]))
        }
        Supervisor::None {
            arguments,
            environment,
        } => {
            stop(pid, state_dir)?;
            start(exe, &arguments[1..], environment.as_deref())
        }
    }
}

/// The checks a hand-off makes before a helper restarts into `exe`, made here because the
/// helper restarted cold cannot make them: the build runs on this host and is not older than
/// the build of this command, which the update installed.
fn check_target(exe: &Path) -> Result<()> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let target = runtime
        .block_on(daemon::restart_target(exe))
        .map_err(anyhow::Error::msg)?;
    let this = daemon::info::build_info(proto::DaemonFeatures::EMPTY);
    if target.is_older_than(&this) {
        bail!(
            "the build {} at {} is older than this command's {}",
            target.build,
            exe.display(),
            this.build
        );
    }
    Ok(())
}

fn run(command: &mut Command) -> Result<()> {
    let status = command
        .status()
        .with_context(|| format!("running {command:?}"))?;
    if !status.success() {
        bail!("{command:?} failed: {status}");
    }
    Ok(())
}

fn helper_process(pid: u32) -> Result<rustix::process::Pid> {
    rustix::process::Pid::from_raw(i32::try_from(pid)?)
        .context("the running helper has no valid pid")
}

fn stop(pid: u32, state_dir: &Path) -> Result<()> {
    rustix::process::kill_process(helper_process(pid)?, rustix::process::Signal::TERM)
        .context("stopping the running helper")?;
    wait_until_stopped(pid, state_dir)
}

/// Waits until the helper let go of the state directory: an exited helper whose parent has
/// not reaped it yet still has a pid.
fn wait_until_stopped(pid: u32, state_dir: &Path) -> Result<()> {
    let process = helper_process(pid)?;
    let deadline = Instant::now() + STOP_WAIT;
    while rustix::process::test_kill_process(process).is_ok() && crate::instance_locked(state_dir) {
        if Instant::now() > deadline {
            bail!(
                "the running helper did not stop within {} s",
                STOP_WAIT.as_secs()
            );
        }
        std::thread::sleep(POLL);
    }
    Ok(())
}

/// Starts `exe` with `arguments` (and `environment`, else this command's) on its own,
/// outliving this command.
fn start(exe: &Path, arguments: &[OsString], environment: Option<&[String]>) -> Result<()> {
    use std::os::unix::process::CommandExt;
    let mut command = Command::new(exe);
    if let Some(environment) = environment {
        command
            .env_clear()
            .envs(environment.iter().filter_map(|entry| entry.split_once('=')));
    }
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .with_context(|| format!("starting {}", exe.display()))?;
    Ok(())
}

fn wait_for_start(state_dir: &Path, started_at: u64) -> Result<()> {
    let deadline = Instant::now() + START_WAIT;
    while Instant::now() < deadline {
        if daemon::endpoint_info(state_dir)
            .ok()
            .flatten()
            .is_some_and(|info| info.started_at > started_at && crate::pid_alive(info.pid))
        {
            return Ok(());
        }
        std::thread::sleep(POLL);
    }
    bail!(
        "the helper did not start again within {} s",
        START_WAIT.as_secs()
    )
}

/// The executable the helper `pid` runs from: where the update put the new build.
pub fn executable_of(pid: u32) -> Option<PathBuf> {
    let program = daemon::process_executable(pid)?;
    Some(program.canonicalize().unwrap_or(program))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_helper_started_by_hand_is_started_again_with_its_arguments() {
        // A label inherited from the terminal it was started in names some other job.
        let mut child = Command::new("/bin/sleep")
            .arg("30")
            .env("XPC_SERVICE_NAME", "application.example.terminal.1")
            .env("INVOCATION_ID", "0123456789abcdef")
            .spawn()
            .unwrap();
        let supervisor = Supervisor::of(child.id(), &ServiceTools::default());
        let _ = child.kill();
        let _ = child.wait();
        let Supervisor::None { arguments, .. } = supervisor.unwrap() else {
            panic!("a supervisor");
        };
        assert_eq!(arguments, ["/bin/sleep", "30"]);
    }

    #[test]
    fn a_helper_is_started_again_with_its_environment() {
        // macOS hides the environment of its own programs such as sleep: read this process's.
        let Supervisor::None { environment, .. } =
            Supervisor::of(std::process::id(), &ServiceTools::default()).unwrap()
        else {
            panic!("a supervisor");
        };
        let path = format!("PATH={}", std::env::var("PATH").unwrap());
        assert!(environment.unwrap().contains(&path));
    }

    #[test]
    fn launchd_says_which_build_its_job_starts() {
        let printed = "gui/501/dev.example.hostd = {\n\tactive count = 1\n\
                       \tpath = /home/u/Library/LaunchAgents/dev.example.hostd.plist\n\
                       \tstate = running\n\n\tprogram = /builds/old/gudo-hostd\n\
                       \targuments = {\n\t\t/builds/old/gudo-hostd\n\t}\n\tpid = 4242\n}\n";
        assert_eq!(
            parse_launchd_job("dev.example.hostd", 4242, printed).unwrap(),
            Some(Job {
                name: "dev.example.hostd".into(),
                definition: "/home/u/Library/LaunchAgents/dev.example.hostd.plist".into(),
                program: "/builds/old/gudo-hostd".into(),
            })
        );
        assert_eq!(
            parse_launchd_job("dev.example.hostd", 7, printed).unwrap(),
            None,
            "a job running another process is not the helper's"
        );
        assert!(parse_launchd_job("x", 4242, "\tpid = 4242\n").is_err());
    }

    #[test]
    fn systemd_says_which_build_its_unit_starts() {
        let shown = "ExecStart={ path=/home/u/old bin/gudo-hostd ; argv[]=/home/u/old bin/gudo-hostd --state-dir /s run ; ignore_errors=no ; start_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n\
                     FragmentPath=/home/u/.config/systemd/user/gudo-hostd.service\n";
        assert_eq!(
            parse_systemd_job("gudo-hostd.service", shown).unwrap(),
            Job {
                name: "gudo-hostd.service".into(),
                definition: "/home/u/.config/systemd/user/gudo-hostd.service".into(),
                program: "/home/u/old bin/gudo-hostd".into(),
            }
        );
        assert!(parse_systemd_job("gudo-hostd.service", "FragmentPath=\n").is_err());
    }

    /// A service manager that records what it was asked.
    struct FakeTools {
        dir: tempfile::TempDir,
        tools: ServiceTools,
    }

    impl FakeTools {
        fn new() -> Self {
            use std::os::unix::fs::PermissionsExt;
            let dir = tempfile::tempdir().unwrap();
            let tool = |name: &str| {
                let path = dir.path().join(name);
                let log = dir.path().join("calls");
                std::fs::write(
                    &path,
                    format!("#!/bin/sh\necho \"{name} $*\" >> '{}'\n", log.display()),
                )
                .unwrap();
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
                path
            };
            let tools = ServiceTools {
                launchctl: tool("launchctl"),
                systemctl: tool("systemctl"),
            };
            Self { dir, tools }
        }

        fn calls(&self) -> Vec<String> {
            std::fs::read_to_string(self.dir.path().join("calls"))
                .unwrap_or_default()
                .lines()
                .map(str::to_owned)
                .collect()
        }

        fn build(&self, name: &str) -> PathBuf {
            let path = self.dir.path().join(name);
            std::fs::write(&path, "").unwrap();
            path.canonicalize().unwrap()
        }
    }

    /// A pid no process has any more.
    fn gone_pid() -> u32 {
        let mut child = Command::new("/usr/bin/true").spawn().unwrap();
        child.wait().unwrap();
        child.id()
    }

    #[test]
    fn a_launchd_job_starting_another_build_is_pointed_at_the_target_and_loaded_again() {
        let fake = FakeTools::new();
        let state = fake.dir.path().join("state");
        let old = fake.build("old");
        let new = fake.build("new");
        let plist = fake.dir.path().join("dev.example.hostd.plist");
        std::fs::write(
            &plist,
            crate::service::launch_agent("dev.example.hostd", &old, &state, Path::new("/logs")),
        )
        .unwrap();
        let job = Job {
            name: "dev.example.hostd".into(),
            definition: plist.clone(),
            program: old.clone(),
        };
        let domain = gui_domain();

        hand_over(
            &Supervisor::Launchd(job.clone()),
            &old,
            &state,
            gone_pid(),
            &fake.tools,
        )
        .unwrap();
        assert_eq!(
            fake.calls(),
            [format!("launchctl kickstart -k {domain}/dev.example.hostd")]
        );

        hand_over(
            &Supervisor::Launchd(job),
            &new,
            &state,
            gone_pid(),
            &fake.tools,
        )
        .unwrap();
        let rewritten = std::fs::read_to_string(&plist).unwrap();
        assert!(rewritten.contains(&format!("<string>{}</string>", new.display())));
        assert!(!rewritten.contains(&format!("<string>{}</string>", old.display())));
        assert_eq!(
            fake.calls()[1..],
            [
                format!("launchctl bootout {domain}/dev.example.hostd"),
                format!("launchctl bootstrap {domain} {}", plist.display()),
            ]
        );
    }

    #[test]
    fn a_job_the_service_command_did_not_install_is_left_alone() {
        let fake = FakeTools::new();
        let state = fake.dir.path().join("state");
        let plist = fake.dir.path().join("app.hostd.plist");
        let foreign = "<plist><dict><key>BundleProgram</key><string>x</string></dict></plist>";
        std::fs::write(&plist, foreign).unwrap();
        let job = Job {
            name: "app.hostd".into(),
            definition: plist.clone(),
            program: fake.build("old"),
        };
        let new = fake.build("new");
        let error = hand_over(
            &Supervisor::Launchd(job),
            &new,
            &state,
            gone_pid(),
            &fake.tools,
        )
        .unwrap_err();
        assert!(error.to_string().contains("service install"), "{error}");
        assert_eq!(std::fs::read_to_string(&plist).unwrap(), foreign);
        assert!(fake.calls().is_empty());
    }

    #[test]
    fn a_systemd_unit_starting_another_build_is_pointed_at_the_target() {
        let fake = FakeTools::new();
        let state = fake.dir.path().join("state");
        let old = fake.build("old");
        let new = fake.build("new");
        let unit = fake.dir.path().join("gudo-hostd.service");
        std::fs::write(&unit, crate::service::systemd_unit(&old, &state).unwrap()).unwrap();
        let job = Job {
            name: "gudo-hostd.service".into(),
            definition: unit.clone(),
            program: old,
        };
        hand_over(
            &Supervisor::Systemd(job),
            &new,
            &state,
            gone_pid(),
            &fake.tools,
        )
        .unwrap();
        let rewritten = std::fs::read_to_string(&unit).unwrap();
        assert!(rewritten.contains(&format!("ExecStart=\"{}\" --state-dir", new.display())));
        assert_eq!(
            fake.calls(),
            [
                "systemctl --user daemon-reload",
                "systemctl --user restart gudo-hostd.service"
            ]
        );
    }
}
