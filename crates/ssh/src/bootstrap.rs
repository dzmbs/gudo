//! Installing the host daemon over SSH and getting a pairing ticket from it, so the client
//! can move to iroh without the user scanning anything.
//!
//! The client picks the binary for the host's platform, verifies its SHA-256 and uploads it;
//! the remote never downloads anything. Each script goes to `sh -s` on stdin, and each round
//! trip pays for the login shell's startup files once more, so the steps share as few as they
//! can:
//!
//! 1. **Probe**: `uname -sm`, `gzip` presence, the SHA-256 and build of an installed binary
//!    and whether its daemon runs.
//! 2. **Upload** (only if the installed binary differs): gzip-compressed when possible,
//!    written to a temp file, SHA-256-checked on the remote, staged next to the install. A
//!    second round trip runs it there. It is installed only once it ran, and over an
//!    installed build that reports its version only if it is not older (rollback
//!    protection: an older app on another device must not quietly reinstate an older
//!    helper), unless [`BootstrapOptions::allow_downgrade`].
//! 3. **Service** (if uploaded or not running), in one round trip with the install: a
//!    running daemon is first asked to restart into the new build in place (`gudo-hostd
//!    restart`), keeping its sessions; else `gudo-hostd service install` (systemd `--user` /
//!    LaunchAgent, restarting an older daemon). Without a service manager (containers, macOS
//!    without a GUI login) the daemon is started detached instead.
//! 4. **Pair**: `gudo-hostd pair --json --wait 30` mints a one-time ticket once the daemon
//!    has recorded its endpoint (after turning lingering on, when it is off).
//!
//! Re-running is cheap and safe: a matching, running install is reused as is.

use std::path::PathBuf;
use std::sync::Arc;

use serde::Deserialize;

use crate::channel::{UploadEncoding, sha256_hex, shell_quote};
use crate::client::Connection;
use crate::{ExecOutput, SshError, UploadReport};

/// The host as the bootstrap uses it: each call is one round trip, which pays for the login
/// shell's startup files once more.
trait Remote: Sync {
    fn run_script(&self, script: &str)
    -> impl Future<Output = Result<ExecOutput, SshError>> + Send;

    fn upload_reporting(
        &self,
        path: &str,
        data: &[u8],
        mode: u32,
        encoding: UploadEncoding,
        on_sent: &(dyn Fn(u64) + Send + Sync),
    ) -> impl Future<Output = Result<UploadReport, SshError>> + Send;
}

impl Remote for Connection {
    fn run_script(
        &self,
        script: &str,
    ) -> impl Future<Output = Result<ExecOutput, SshError>> + Send {
        Connection::run_script(self, script)
    }

    fn upload_reporting(
        &self,
        path: &str,
        data: &[u8],
        mode: u32,
        encoding: UploadEncoding,
        on_sent: &(dyn Fn(u64) + Send + Sync),
    ) -> impl Future<Output = Result<UploadReport, SshError>> + Send {
        Connection::upload_reporting(self, path, data, mode, encoding, on_sent)
    }
}

/// An OS and CPU the daemon is built for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum HostPlatform {
    /// Linux on arm64 (Graviton, Ampere, Raspberry Pi 4+, OrbStack on Apple silicon).
    LinuxAarch64,
    /// Linux on x86-64.
    LinuxX86_64,
    /// macOS on Apple silicon.
    MacosAarch64,
    /// macOS on Intel.
    MacosX86_64,
}

impl HostPlatform {
    /// Parses `uname -s` and `uname -m`.
    ///
    /// # Examples
    ///
    /// ```
    /// use ssh::HostPlatform;
    /// assert_eq!(HostPlatform::from_uname("Linux", "x86_64"), Some(HostPlatform::LinuxX86_64));
    /// assert_eq!(HostPlatform::from_uname("Darwin", "arm64"), Some(HostPlatform::MacosAarch64));
    /// assert_eq!(HostPlatform::from_uname("FreeBSD", "amd64"), None);
    /// ```
    pub fn from_uname(os: &str, arch: &str) -> Option<Self> {
        let arm = matches!(arch, "aarch64" | "arm64" | "aarch64_be");
        let x86 = matches!(arch, "x86_64" | "amd64");
        match os {
            "Linux" if arm => Some(Self::LinuxAarch64),
            "Linux" if x86 => Some(Self::LinuxX86_64),
            "Darwin" if arm => Some(Self::MacosAarch64),
            "Darwin" if x86 => Some(Self::MacosX86_64),
            _ => None,
        }
    }

    /// The Rust target triple of the matching build (static musl on Linux).
    pub fn rust_target(self) -> &'static str {
        match self {
            Self::LinuxAarch64 => "aarch64-unknown-linux-musl",
            Self::LinuxX86_64 => "x86_64-unknown-linux-musl",
            Self::MacosAarch64 => "aarch64-apple-darwin",
            Self::MacosX86_64 => "x86_64-apple-darwin",
        }
    }

    pub fn is_macos(self) -> bool {
        matches!(self, Self::MacosAarch64 | Self::MacosX86_64)
    }

    /// Where the daemon binary is installed, relative to `$HOME`.
    pub fn install_path(self) -> String {
        if self.is_macos() {
            format!(
                "Library/Application Support/{}/bin/{}",
                brand::DIR_NAME,
                brand::DAEMON_BIN
            )
        } else {
            format!(".local/bin/{}", brand::DAEMON_BIN)
        }
    }
}

/// A daemon build to install.
#[derive(Debug, Clone)]
pub enum BinarySource {
    /// The binary itself.
    Bytes(Arc<Vec<u8>>),
    /// A file to read it from (e.g. inside the app bundle).
    Path(PathBuf),
}

impl BinarySource {
    async fn load(&self) -> Result<Arc<Vec<u8>>, SshError> {
        match self {
            Self::Bytes(bytes) => Ok(Arc::clone(bytes)),
            Self::Path(path) => tokio::fs::read(path)
                .await
                .map(Arc::new)
                .map_err(|error| SshError::io(format!("reading {}", path.display()), error)),
        }
    }
}

/// The daemon builds the caller has, per platform (`cargo zigbuild --release -p hostd
/// --target {aarch64,x86_64}-unknown-linux-musl`, `cargo build --release -p hostd` on a
/// Mac).
#[derive(Debug, Clone, Default)]
pub struct HostdBinaries {
    /// `aarch64-unknown-linux-musl`.
    pub linux_aarch64: Option<BinarySource>,
    /// `x86_64-unknown-linux-musl`.
    pub linux_x86_64: Option<BinarySource>,
    /// `aarch64-apple-darwin`.
    pub macos_aarch64: Option<BinarySource>,
    /// `x86_64-apple-darwin`.
    pub macos_x86_64: Option<BinarySource>,
}

impl HostdBinaries {
    pub fn get(&self, platform: HostPlatform) -> Option<&BinarySource> {
        match platform {
            HostPlatform::LinuxAarch64 => self.linux_aarch64.as_ref(),
            HostPlatform::LinuxX86_64 => self.linux_x86_64.as_ref(),
            HostPlatform::MacosAarch64 => self.macos_aarch64.as_ref(),
            HostPlatform::MacosX86_64 => self.macos_x86_64.as_ref(),
        }
    }
}

/// Progress, for a "Setting up `host`…" sheet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BootstrapStep {
    /// Detecting the platform and any existing install.
    Probing,
    /// Uploading the daemon: `sent` of its `size` bytes so far (counted in the binary's bytes
    /// when the wire carries it compressed).
    Uploading { size: u64, sent: u64 },
    /// Installing and starting the service.
    Starting,
    /// Waiting for the daemon and minting a ticket.
    Pairing,
}

/// Receives [`BootstrapStep`]s.
pub trait BootstrapListener: Send + Sync {
    fn on_step(&self, step: BootstrapStep);
}

#[derive(Clone, Default)]
pub struct BootstrapOptions {
    /// Ticket lifetime in minutes (default 10).
    pub ticket_minutes: Option<u32>,
    /// Seconds to wait for the daemon to come up (default 30).
    pub wait_secs: Option<u32>,
    pub listener: Option<Arc<dyn BootstrapListener>>,
    /// Replace an installed build even when it is newer than the one supplied. Off by
    /// default: a newer installed helper is kept ([`InstallAction::KeptNewer`]).
    pub allow_downgrade: bool,
}

/// What the bootstrap did to the binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallAction {
    /// Nothing was installed before.
    Installed,
    /// A different build was replaced.
    Upgraded,
    /// The installed build matched and was kept.
    Reused,
    /// The installed build is newer than the one supplied and was kept.
    KeptNewer,
}

/// How the daemon runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServiceMode {
    /// Under systemd `--user` or launchd: restarts on failure and at login.
    Service,
    /// Started detached because no service manager was usable; it will not come back
    /// after a reboot.
    Detached,
    /// It was already running; left alone, or restarted in place into the new build.
    AlreadyRunning,
}

/// The outcome of [`bootstrap`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapReport {
    pub platform: HostPlatform,
    pub action: InstallAction,
    pub service: ServiceMode,
    /// Absolute install path on the host.
    pub install_path: String,
    /// SHA-256 of the installed binary, hex.
    pub sha256: String,
    /// `gudo://pair/…` ticket, valid for one device.
    pub ticket: String,
    /// The daemon's endpoint id, hex.
    pub daemon_id: String,
    /// Things the user may want to know (e.g. how to enable lingering).
    pub notes: Vec<String>,
}

#[derive(Debug, Default)]
struct Probe {
    os: String,
    arch: String,
    home: String,
    gzip: bool,
    sha256: Option<String>,
    /// What the installed binary reports about itself (`build-info --json`).
    installed: Option<proto::DaemonInfo>,
    running: bool,
    linger: Option<bool>,
}

impl Probe {
    fn platform(&self) -> Result<HostPlatform, SshError> {
        if self.os.is_empty() {
            // The probe's commands never ran: something in the login shell's startup took
            // over, as `exec zsh` in ~/.bashrc does.
            return Err(SshError::Bootstrap(
                "the host ran none of the setup commands. Something in its shell startup \
                 (~/.bashrc, ~/.profile) may start another shell, such as `exec zsh`; \
                 run that only in interactive shells"
                    .into(),
            ));
        }
        HostPlatform::from_uname(&self.os, &self.arch).ok_or_else(|| {
            SshError::Bootstrap(format!("unsupported platform {} {}", self.os, self.arch))
        })
    }
}

#[derive(Deserialize)]
struct PairJson {
    ticket: String,
    daemon_id: String,
}

/// Installs (or reuses) the daemon on the host behind `connection`, makes sure it runs, and
/// returns a fresh pairing ticket for it.
///
/// # Errors
///
/// [`SshError::Bootstrap`] for an unsupported platform or a missing build,
/// [`SshError::ChecksumMismatch`] if the upload arrived corrupted, [`SshError::Remote`]
/// if a remote step fails.
pub async fn bootstrap(
    connection: &Connection,
    binaries: &HostdBinaries,
    options: &BootstrapOptions,
) -> Result<BootstrapReport, SshError> {
    bootstrap_on(connection, binaries, options).await
}

async fn bootstrap_on(
    connection: &impl Remote,
    binaries: &HostdBinaries,
    options: &BootstrapOptions,
) -> Result<BootstrapReport, SshError> {
    let step = |step: BootstrapStep| {
        if let Some(listener) = &options.listener {
            listener.on_step(step);
        }
    };
    step(BootstrapStep::Probing);
    let probe = probe(connection).await?;
    let platform = probe.platform()?;
    let source = binaries.get(platform).ok_or_else(|| {
        SshError::Bootstrap(format!(
            "no {} build supplied ({})",
            brand::DAEMON_BIN,
            platform.rust_target()
        ))
    })?;
    let binary = source.load().await?;
    let sha256 = sha256_hex(&binary);
    let relative_path = platform.install_path();
    let install_path = format!("{}/{relative_path}", probe.home);
    let hostd = home_path(&relative_path);

    let mut action = match &probe.sha256 {
        Some(installed_sha256) if *installed_sha256 == sha256 => InstallAction::Reused,
        Some(_) => InstallAction::Upgraded,
        None => InstallAction::Installed,
    };
    let staged = staged_path(&relative_path);
    if action != InstallAction::Reused {
        let encoding = if probe.gzip {
            UploadEncoding::Gzip
        } else {
            UploadEncoding::Raw
        };
        // Staged next to the install first: it must run here, and must not be older than a
        // build that reports its version.
        step(BootstrapStep::Uploading {
            size: binary.len() as u64,
            sent: 0,
        });
        let size = binary.len() as u64;
        let report = connection
            .upload_reporting(&format!("~/{staged}"), &binary, 0o755, encoding, &|sent| {
                step(BootstrapStep::Uploading { size, sent });
            })
            .await
            .map_err(|error| out_of_space(error, &relative_path, size))?;
        step(BootstrapStep::Uploading {
            size: report.size,
            sent: report.size,
        });
        if check_staged(
            connection,
            &staged,
            &relative_path,
            probe.installed.as_ref(),
            options,
        )
        .await?
            == StagedBuild::Older
        {
            action = InstallAction::KeptNewer;
        }
    }

    let mut notes = Vec::new();
    if action == InstallAction::KeptNewer {
        notes.push(
            "This host already runs a newer helper than this app carries; it was kept. \
             Update the app if it cannot connect."
                .into(),
        );
    }
    let kept = matches!(action, InstallAction::Reused | InstallAction::KeptNewer);
    let start = if kept && probe.running {
        None
    } else if action == InstallAction::Upgraded && probe.running {
        // A running daemon that can restart in place hands its sessions to the new build;
        // otherwise (it predates that, or the new build cannot take them over) the service
        // restarts it, ending them.
        Some(Start::RestartInPlace)
    } else {
        Some(Start::Service)
    };
    if start.is_some() {
        step(BootstrapStep::Starting);
    }
    let service = if start.is_none() && action == InstallAction::Reused {
        ServiceMode::AlreadyRunning
    } else {
        let script = activation_script(&hostd, &staged, &relative_path, action, start);
        let output = connection.run_script(&script).await?.check()?;
        let started = Started::parse(&output.stdout_text());
        match started {
            Started::Detached { service_output } => {
                tracing::info!("service install failed, starting detached: {service_output}");
                notes.push(DETACHED_NOTE.into());
                ServiceMode::Detached
            }
            Started::Service => ServiceMode::Service,
            Started::InPlace | Started::Untouched => ServiceMode::AlreadyRunning,
        }
    };
    let user_service = matches!(service, ServiceMode::Service | ServiceMode::AlreadyRunning);
    let enables_linger = !platform.is_macos() && user_service && probe.linger == Some(false);

    step(BootstrapStep::Pairing);
    let minutes = options.ticket_minutes.unwrap_or(10);
    let wait = options.wait_secs.unwrap_or(30);
    let mut script = String::new();
    if enables_linger {
        script.push_str(ENABLE_LINGER);
    }
    script.push_str(&format!(
        "{hostd} pair --json --wait {wait} --minutes {minutes}\n"
    ));
    let output = connection.run_script(&script).await?.check()?;
    if enables_linger
        && !output
            .stdout_text()
            .lines()
            .any(|line| line == "linger=yes")
    {
        notes.push(
            "Lingering is off, so the daemon stops when you log out. Run once: \
             sudo loginctl enable-linger \"$USER\""
                .into(),
        );
    }
    let json = output
        .stdout_text()
        .lines()
        .rev()
        .find(|line| line.trim_start().starts_with('{'))
        .map(str::to_owned)
        .ok_or_else(|| {
            SshError::Bootstrap(format!("no JSON from pair: {}", output.stdout_text()))
        })?;
    let pair: PairJson = serde_json::from_str(&json)
        .map_err(|error| SshError::Bootstrap(format!("bad JSON from pair ({error}): {json}")))?;
    let sha256 = match action {
        InstallAction::KeptNewer => probe.sha256.unwrap_or_default(),
        _ => sha256,
    };
    Ok(BootstrapReport {
        platform,
        action,
        service,
        install_path,
        sha256,
        ticket: pair.ticket,
        daemon_id: pair.daemon_id,
        notes,
    })
}

/// Where a build is staged next to the installed one (paths relative to `$HOME`).
fn staged_path(relative_path: &str) -> String {
    match relative_path.rsplit_once('/') {
        Some((dir, name)) => format!("{dir}/.{name}.new"),
        None => format!(".{relative_path}.new"),
    }
}

const DETACHED_NOTE: &str = "This host has no service manager the helper can use, so it runs in \
     the background and won't start again after a reboot.";

/// Whether the staged build may replace the installed one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StagedBuild {
    Install,
    /// Older than the installed build, and no downgrade was asked for: the installed build
    /// stays ([`InstallAction::KeptNewer`]).
    Older,
}

/// Runs the staged build once here (`build-info`). A build that cannot run is deleted.
async fn check_staged(
    connection: &impl Remote,
    staged: &str,
    relative_path: &str,
    installed: Option<&proto::DaemonInfo>,
    options: &BootstrapOptions,
) -> Result<StagedBuild, SshError> {
    let staged_quoted = home_path(staged);
    let output = connection
        .run_script(&format!(
            "{staged_quoted} build-info --json 2>&1 || {{ status=$?; rm -f {staged_quoted}; exit $status; }}\n"
        ))
        .await?;
    let supplied = output
        .success()
        .then(|| build_info(&output.stdout_text()))
        .flatten();
    let Some(supplied) = supplied else {
        return Err(SshError::Bootstrap(cannot_run_message(
            relative_path,
            output.stdout_text().trim(),
        )));
    };
    if let Some(installed) = installed
        && supplied.is_older_than(installed)
        && !options.allow_downgrade
    {
        tracing::info!(installed = %installed.build, supplied = %supplied.build, "keeping the newer installed daemon");
        return Ok(StagedBuild::Older);
    }
    Ok(StagedBuild::Install)
}

/// `~/relative_path` quoted for sh.
fn home_path(relative_path: &str) -> String {
    format!("\"$HOME\"/{}", shell_quote(relative_path))
}

/// How the daemon is (re)started after an install.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Start {
    /// Ask the running daemon to restart into the new build, else as [`Start::Service`].
    RestartInPlace,
    /// Install the service (which restarts a running daemon), else start it detached.
    Service,
}

/// What [`activation_script`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Started {
    Untouched,
    InPlace,
    Service,
    Detached { service_output: String },
}

impl Started {
    fn parse(text: &str) -> Self {
        let service_output = text
            .lines()
            .filter_map(|line| line.strip_prefix("service-output="))
            .collect::<Vec<_>>()
            .join("\n");
        match text
            .lines()
            .rev()
            .find_map(|line| line.strip_prefix("started="))
        {
            Some("in-place") => Self::InPlace,
            Some("service") => Self::Service,
            Some("detached") => Self::Detached { service_output },
            _ => Self::Untouched,
        }
    }
}

/// One round trip after the upload: moves the staged build into place (or deletes it when
/// the installed one is kept), then starts the daemon as `start` says.
fn activation_script(
    hostd: &str,
    staged: &str,
    relative_path: &str,
    action: InstallAction,
    start: Option<Start>,
) -> String {
    let staged = home_path(staged);
    let mut script = match action {
        InstallAction::Installed | InstallAction::Upgraded => {
            format!("mv -f {staged} {} || exit 1\n", home_path(relative_path))
        }
        InstallAction::KeptNewer => format!("rm -f {staged}\n"),
        InstallAction::Reused => String::new(),
    };
    if start == Some(Start::RestartInPlace) {
        script.push_str(&format!(
            "if {hostd} restart >/dev/null 2>&1; then echo started=in-place; exit 0; fi\n"
        ));
    }
    if start.is_some() {
        script.push_str(&format!(
            r#"if output=$({hostd} service install 2>&1); then
  echo started=service
else
  printf '%s\n' "$output" | sed 's/^/service-output=/'
  log="$(dirname {hostd})/hostd.log"
  cd ~ && (command -v setsid >/dev/null 2>&1 && exec setsid {hostd} run --log-file "$log" || exec {hostd} run --log-file "$log") </dev/null >>"$log" 2>&1 &
  echo started=detached
fi
"#
        ));
    }
    script
}

/// A full disk under the install, said as such rather than as the failed command's words.
fn out_of_space(error: SshError, relative_path: &str, size: u64) -> SshError {
    match &error {
        SshError::Remote { stderr, .. } if stderr.contains("No space left on device") => {
            let folder = relative_path
                .rsplit_once('/')
                .map_or("", |(folder, _)| folder);
            SshError::Bootstrap(format!(
                "the host has no room for the helper: it needs about {} MB free in ~/{folder}",
                size.div_ceil(1_000_000)
            ))
        }
        _ => error,
    }
}

fn cannot_run_message(relative_path: &str, output: &str) -> String {
    let folder = relative_path
        .rsplit_once('/')
        .map_or("", |(folder, _)| folder);
    if output.contains("Permission denied") {
        format!(
            "this host does not let programs run from ~/{folder} (its file system may be \
             mounted noexec): {output}"
        )
    } else {
        format!(
            "the {} build does not run on this host: {output}",
            brand::DAEMON_BIN
        )
    }
}

/// The last JSON line of `build-info --json` output.
fn build_info(text: &str) -> Option<proto::DaemonInfo> {
    let line = text
        .lines()
        .rev()
        .find(|line| line.trim_start().starts_with('{'))?;
    serde_json::from_str(line).ok()
}

/// Detects the platform with `uname -sm` (separately, so odd `uname` output stays
/// parseable).
pub async fn detect_platform(connection: &Connection) -> Result<HostPlatform, SshError> {
    probe(connection).await?.platform()
}

async fn probe(connection: &impl Remote) -> Result<Probe, SshError> {
    let script = format!(
        r#"echo "os=$(uname -s)"
echo "arch=$(uname -m)"
echo "home=$HOME"
command -v gzip >/dev/null 2>&1 && echo gzip=1
case "$(uname -s)" in
  Darwin) bin="$HOME/{mac}" ;;
  *) bin="$HOME/{linux}" ;;
esac
if [ -x "$bin" ]; then
  echo "sha256=$( (sha256sum "$bin" 2>/dev/null || shasum -a 256 "$bin" 2>/dev/null || openssl dgst -sha256 -r "$bin") | cut -d' ' -f1)"
  "$bin" status 2>/dev/null | head -n 1 | sed 's/^/status=/'
  "$bin" build-info --json 2>/dev/null | grep '^{{' | tail -n 1 | sed 's/^/info=/'
fi
if command -v loginctl >/dev/null 2>&1; then
  echo "linger=$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)"
fi
true"#,
        mac = HostPlatform::MacosAarch64.install_path(),
        linux = HostPlatform::LinuxAarch64.install_path(),
    );
    let output = connection.run_script(&script).await?.check()?;
    Ok(parse_probe(&output.stdout_text()))
}

fn parse_probe(text: &str) -> Probe {
    let mut probe = Probe::default();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        match key {
            "os" => probe.os = value.to_owned(),
            "arch" => probe.arch = value.to_owned(),
            "home" => probe.home = value.to_owned(),
            "gzip" => probe.gzip = value == "1",
            "sha256" if value.len() == 64 => probe.sha256 = Some(value.to_ascii_lowercase()),
            "status" => probe.running = value.starts_with("running"),
            "info" => probe.installed = build_info(value),
            "linger" => probe.linger = Some(value == "yes"),
            _ => {}
        }
    }
    probe
}

/// Without lingering, systemd stops a user's services (the daemon) when their last session
/// ends, which is the SSH session that installed it. Most distributions' polkit rules let a
/// user enable lingering for themselves without a password, so try that before falling back
/// to a note (`--no-ask-password`: never prompt). Prints `linger=yes` once it is on.
const ENABLE_LINGER: &str = "loginctl --no-ask-password enable-linger \"$(id -un)\" >/dev/null 2>&1
echo \"linger=$(loginctl show-user \"$(id -un)\" -p Linger --value 2>/dev/null)\"
";

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    const NEW_BUILD: &[u8] = b"new build";
    const OLD_BUILD: &[u8] = b"old build";

    fn build_info_json(build: &str, built_unix: u64) -> String {
        format!(
            r#"{{"version":"0.1.0","build":"{build}","built_unix":{built_unix},"protocol":1,"min_client_protocol":0,"features":0,"hostname":"h","os":"linux","os_name":"","arch":"x86_64"}}"#
        )
    }

    /// A Linux host answering the bootstrap's scripts, counting the round trips.
    #[derive(Default)]
    struct ScriptedHost {
        installed: Option<&'static [u8]>,
        running: bool,
        has_systemd: bool,
        commands: Mutex<Vec<String>>,
    }

    impl ScriptedHost {
        fn answer(&self, script: &str) -> ExecOutput {
            let mut output = ExecOutput {
                exit_status: Some(0),
                ..ExecOutput::default()
            };
            let stdout = if script.contains("uname -s") {
                let mut lines =
                    String::from("os=Linux\narch=x86_64\nhome=/home/u\ngzip=1\nlinger=yes\n");
                if let Some(installed) = self.installed {
                    lines += &format!("sha256={}\n", sha256_hex(installed));
                    lines += &format!("info={}\n", build_info_json("old", 1));
                    if self.running {
                        lines += "status=running (pid 9)\n";
                    }
                }
                lines
            } else if script.contains("build-info --json") {
                build_info_json("new", 2)
            } else if script.contains("pair --json") {
                r#"{"ticket":"gudo://pair/t","daemon_id":"ab"}"#.to_owned()
            } else if script.contains("started=") {
                if script.contains(" restart") && self.running {
                    "started=in-place\n".to_owned()
                } else if self.has_systemd {
                    "started=service\n".to_owned()
                } else {
                    "service-output=Error: no systemd here\nstarted=detached\n".to_owned()
                }
            } else {
                String::new()
            };
            output.stdout = stdout.into_bytes();
            output
        }

        fn round_trips(&self) -> usize {
            self.commands.lock().unwrap().len()
        }
    }

    impl Remote for ScriptedHost {
        fn run_script(
            &self,
            script: &str,
        ) -> impl Future<Output = Result<ExecOutput, SshError>> + Send {
            self.commands.lock().unwrap().push(script.to_owned());
            std::future::ready(Ok(self.answer(script)))
        }

        fn upload_reporting(
            &self,
            path: &str,
            data: &[u8],
            _mode: u32,
            _encoding: UploadEncoding,
            _on_sent: &(dyn Fn(u64) + Send + Sync),
        ) -> impl Future<Output = Result<UploadReport, SshError>> + Send {
            self.commands.lock().unwrap().push(format!("upload {path}"));
            std::future::ready(Ok(UploadReport {
                path: path.to_owned(),
                size: data.len() as u64,
                sha256: sha256_hex(data),
                sent: data.len() as u64,
            }))
        }
    }

    async fn round_trips(host: ScriptedHost) -> (usize, BootstrapReport) {
        let binaries = HostdBinaries {
            linux_x86_64: Some(BinarySource::Bytes(Arc::new(NEW_BUILD.to_vec()))),
            ..HostdBinaries::default()
        };
        let report = bootstrap_on(&host, &binaries, &BootstrapOptions::default())
            .await
            .unwrap();
        (host.round_trips(), report)
    }

    #[tokio::test]
    async fn each_kind_of_bootstrap_makes_few_round_trips() {
        let (fresh, report) = round_trips(ScriptedHost {
            has_systemd: true,
            ..ScriptedHost::default()
        })
        .await;
        assert_eq!(report.service, ServiceMode::Service);
        let (detached, report) = round_trips(ScriptedHost::default()).await;
        assert_eq!(report.service, ServiceMode::Detached);
        assert_eq!(report.notes, [DETACHED_NOTE]);
        let (upgrade, report) = round_trips(ScriptedHost {
            installed: Some(OLD_BUILD),
            running: true,
            has_systemd: true,
            ..ScriptedHost::default()
        })
        .await;
        assert_eq!(
            (report.action, report.service),
            (InstallAction::Upgraded, ServiceMode::AlreadyRunning)
        );
        let (reuse, report) = round_trips(ScriptedHost {
            installed: Some(NEW_BUILD),
            running: true,
            has_systemd: true,
            ..ScriptedHost::default()
        })
        .await;
        assert_eq!(report.action, InstallAction::Reused);
        assert_eq!((fresh, detached, upgrade, reuse), (5, 5, 5, 2));
    }

    #[test]
    fn probe_parsing() {
        let probe = parse_probe(
            "os=Linux\narch=aarch64\nhome=/home/u\ngzip=1\nsha256=ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n\
             status=running (pid 12, state dir /x)\nlinger=no\n",
        );
        assert_eq!(
            HostPlatform::from_uname(&probe.os, &probe.arch),
            Some(HostPlatform::LinuxAarch64)
        );
        assert_eq!(probe.home, "/home/u");
        assert!(probe.gzip && probe.running);
        assert_eq!(probe.sha256.unwrap().len(), 64);
        assert_eq!(probe.linger, Some(false));
        let macos =
            parse_probe("os=Darwin\narch=arm64\nhome=/Users/u\nstatus=not running (pid 3)\n");
        assert!(!macos.running && !macos.gzip && macos.sha256.is_none());
    }

    #[test]
    fn probe_reads_the_installed_build() {
        let probe = parse_probe(concat!(
            "os=Linux\narch=x86_64\nhome=/h\n",
            r#"info={"version":"0.1.0","build":"abc=1","built_unix":5,"protocol":1,"min_client_protocol":0,"features":0,"hostname":"h","os":"linux","os_name":"","arch":"x86_64"}"#,
            "\n"
        ));
        let info = probe.installed.expect("installed build");
        assert_eq!((info.build.as_str(), info.built_unix), ("abc=1", 5));
        assert!(parse_probe("info=not json\n").installed.is_none());
    }

    #[test]
    fn a_probe_that_never_ran_says_why() {
        let error = parse_probe("").platform().unwrap_err();
        assert!(error.to_string().contains("exec zsh"), "{error}");
        let error = parse_probe("os=FreeBSD\narch=amd64\n")
            .platform()
            .unwrap_err();
        assert!(
            error.to_string().contains("unsupported platform FreeBSD"),
            "{error}"
        );
    }

    #[test]
    fn a_full_disk_is_named_with_the_room_needed() {
        let full = SshError::Remote {
            status: "exit 1".into(),
            stderr: "gzip: stdout: No space left on device".into(),
        };
        let error = out_of_space(full, ".local/bin/gudo-hostd", 37_940_960);
        assert_eq!(
            error.to_string(),
            "bootstrap: the host has no room for the helper: it needs about 38 MB free in \
             ~/.local/bin"
        );
        let other = SshError::Remote {
            status: "exit 1".into(),
            stderr: "mkdir: Permission denied".into(),
        };
        assert!(matches!(
            out_of_space(other, ".local/bin/gudo-hostd", 1),
            SshError::Remote { .. }
        ));
    }

    /// Runs [`activation_script`] under `sh` in a home whose helper answers `service`
    /// and `restart` as told, and parses what it did.
    fn activate(
        start: Option<Start>,
        service_works: bool,
        restart_works: bool,
    ) -> (Started, tempfile::TempDir) {
        let home = tempfile::tempdir().unwrap();
        let bin = home.path().join("bin dir");
        std::fs::create_dir_all(&bin).unwrap();
        let helper = format!(
            "#!/bin/sh\ncase \"$1\" in\n  service) {service} ;;\n  restart) {restart} ;;\n  run) echo \"running $2\" ;;\nesac\n",
            service = if service_works {
                "exit 0"
            } else {
                "echo 'Error: no systemd here'; exit 1"
            },
            restart = if restart_works { "exit 0" } else { "exit 1" },
        );
        let staged = bin.join(".hostd.new");
        std::fs::write(&staged, helper).unwrap();
        std::fs::set_permissions(&staged, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let script = activation_script(
            &home_path("bin dir/hostd"),
            "bin dir/.hostd.new",
            "bin dir/hostd",
            InstallAction::Upgraded,
            start,
        );
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(&script)
            .env("HOME", home.path())
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        assert!(bin.join("hostd").exists() && !staged.exists());
        (
            Started::parse(&String::from_utf8_lossy(&output.stdout)),
            home,
        )
    }

    #[test]
    fn activation_installs_then_starts_the_daemon_the_best_way_it_can() {
        assert_eq!(
            activate(Some(Start::RestartInPlace), false, true).0,
            Started::InPlace
        );
        assert_eq!(
            activate(Some(Start::RestartInPlace), true, false).0,
            Started::Service
        );
        assert_eq!(
            activate(Some(Start::Service), true, true).0,
            Started::Service
        );
        assert_eq!(activate(None, false, false).0, Started::Untouched);
        let (started, home) = activate(Some(Start::Service), false, false);
        assert_eq!(
            started,
            Started::Detached {
                service_output: "Error: no systemd here".into()
            }
        );
        let log = home.path().join("bin dir/hostd.log");
        for _ in 0..50 {
            if std::fs::read_to_string(&log).is_ok_and(|text| text.contains("running --log-file")) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        panic!("the detached daemon never wrote to {}", log.display());
    }

    #[test]
    fn staging_sits_next_to_the_install() {
        assert_eq!(
            staged_path(".local/bin/gudo-hostd"),
            ".local/bin/.gudo-hostd.new"
        );
        assert_eq!(staged_path("hostd"), ".hostd.new");
    }

    #[test]
    fn install_paths() {
        assert_eq!(
            HostPlatform::LinuxX86_64.install_path(),
            format!(".local/bin/{}", brand::DAEMON_BIN)
        );
        assert!(
            HostPlatform::MacosAarch64
                .install_path()
                .starts_with("Library/Application Support/")
        );
    }
}
