//! Installing the host daemon over SSH and getting a pairing ticket from it, so the client
//! can move to iroh without the user scanning anything.
//!
//! The client picks the binary for the host's platform, verifies its SHA-256 and uploads it; the remote never
//! downloads anything. Steps, each one `exec` round trip:
//!
//! 1. **Probe**: `uname -sm`, `gzip` presence, the SHA-256 and build of an installed binary
//!    and whether its daemon runs.
//! 2. **Upload** (only if the installed binary differs): gzip-compressed when possible,
//!    written to a temp file, SHA-256-checked on the remote, renamed into place. Over an
//!    installed build that reports its version, the new one is staged next to it first and
//!    only replaces it if it is not older (rollback protection: an older app on another
//!    device must not quietly reinstate an older helper), unless
//!    [`BootstrapOptions::allow_downgrade`].
//! 3. **Service** (if uploaded or not running): a running daemon is first asked to restart
//!    into the new build in place (`gudo-hostd restart`), keeping its sessions; else
//!    `gudo-hostd service install` (systemd `--user` / LaunchAgent, restarting an older
//!    daemon). Without a service manager
//!    (containers, macOS without a GUI login) the daemon is started detached instead.
//! 4. **Pair**: `gudo-hostd pair --json --wait 30` mints a one-time ticket once the
//!    daemon has recorded its endpoint.
//!
//! Re-running is cheap and safe: a matching, running install is reused as is.

use std::path::PathBuf;
use std::sync::Arc;

use serde::Deserialize;

use crate::SshError;
use crate::channel::{UploadEncoding, sh_command, sha256_hex, shell_quote};
use crate::client::Connection;

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
    /// Uploading the daemon (`size` bytes of binary, `sent` on the wire).
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
    let step = |step: BootstrapStep| {
        if let Some(listener) = &options.listener {
            listener.on_step(step);
        }
    };
    step(BootstrapStep::Probing);
    let probe = probe(connection).await?;
    let platform = HostPlatform::from_uname(&probe.os, &probe.arch).ok_or_else(|| {
        SshError::Bootstrap(format!("unsupported platform {} {}", probe.os, probe.arch))
    })?;
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
    let hostd = format!("\"$HOME\"/{}", shell_quote(&relative_path));

    let mut action = match &probe.sha256 {
        Some(installed_sha256) if *installed_sha256 == sha256 => InstallAction::Reused,
        Some(_) => InstallAction::Upgraded,
        None => InstallAction::Installed,
    };
    if action != InstallAction::Reused {
        let encoding = if probe.gzip {
            UploadEncoding::Gzip
        } else {
            UploadEncoding::Raw
        };
        // Over a build that reports its version, stage first and compare.
        let staged = probe
            .installed
            .as_ref()
            .map(|_| staged_path(&relative_path));
        step(BootstrapStep::Uploading {
            size: binary.len() as u64,
            sent: 0,
        });
        let report = connection
            .upload(
                &format!("~/{}", staged.as_deref().unwrap_or(&relative_path)),
                &binary,
                0o755,
                encoding,
            )
            .await?;
        step(BootstrapStep::Uploading {
            size: report.size,
            sent: report.sent,
        });
        if let (Some(staged), Some(installed)) = (&staged, &probe.installed) {
            action = replace_unless_older(connection, staged, &relative_path, installed, options)
                .await?;
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
    // A running daemon that can restart in place hands its sessions to the new build;
    // otherwise (it predates that, or the new build cannot take them over) the service
    // restarts it below, ending them.
    let restarted_in_place = action == InstallAction::Upgraded
        && probe.running
        && connection
            .exec(&sh_command(&format!("{hostd} restart 2>&1")))
            .await?
            .success();
    let service = if (kept || restarted_in_place) && probe.running {
        ServiceMode::AlreadyRunning
    } else {
        step(BootstrapStep::Starting);
        let output = connection
            .exec(&sh_command(&format!("{hostd} service install 2>&1")))
            .await?;
        if output.success() {
            ServiceMode::Service
        } else {
            tracing::info!(
                "service install failed, starting detached: {}",
                output.stdout_text().trim()
            );
            notes.push(format!(
                "No usable service manager ({}); the daemon was started in the background and \
                 will not restart after a reboot.",
                output.stdout_text().lines().last().unwrap_or("").trim()
            ));
            let start = format!(
                "cd ~ && (command -v setsid >/dev/null 2>&1 && exec setsid {hostd} run || exec {hostd} run) \
                 </dev/null >>\"$(dirname {hostd})/hostd.log\" 2>&1 &"
            );
            connection.exec(&sh_command(&start)).await?.check()?;
            ServiceMode::Detached
        }
    };
    let user_service = matches!(service, ServiceMode::Service | ServiceMode::AlreadyRunning);
    if !platform.is_macos()
        && user_service
        && probe.linger == Some(false)
        && !enable_linger(connection).await?
    {
        notes.push(
            "Lingering is off, so the daemon stops when you log out. Run once: \
             sudo loginctl enable-linger \"$USER\""
                .into(),
        );
    }

    step(BootstrapStep::Pairing);
    let minutes = options.ticket_minutes.unwrap_or(10);
    let wait = options.wait_secs.unwrap_or(30);
    let output = connection
        .exec(&sh_command(&format!(
            "{hostd} pair --json --wait {wait} --minutes {minutes}"
        )))
        .await?
        .check()?;
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

/// Moves the staged build over the installed one unless it is older (and no downgrade was
/// asked for), in which case it is deleted and the installed build stays.
async fn replace_unless_older(
    connection: &Connection,
    staged: &str,
    relative_path: &str,
    installed: &proto::DaemonInfo,
    options: &BootstrapOptions,
) -> Result<InstallAction, SshError> {
    let staged_quoted = format!("\"$HOME\"/{}", shell_quote(staged));
    let output = connection
        .exec(&sh_command(&format!(
            "{staged_quoted} build-info --json 2>&1"
        )))
        .await?;
    let supplied = output
        .success()
        .then(|| build_info(&output.stdout_text()))
        .flatten();
    let Some(supplied) = supplied else {
        connection
            .exec(&sh_command(&format!("rm -f {staged_quoted}")))
            .await?;
        return Err(SshError::Bootstrap(format!(
            "the {} build does not run on this host: {}",
            brand::DAEMON_BIN,
            output.stdout_text().trim()
        )));
    };
    if supplied.is_older_than(installed) && !options.allow_downgrade {
        tracing::info!(installed = %installed.build, supplied = %supplied.build, "keeping the newer installed daemon");
        connection
            .exec(&sh_command(&format!("rm -f {staged_quoted}")))
            .await?;
        return Ok(InstallAction::KeptNewer);
    }
    connection
        .exec(&sh_command(&format!(
            "mv -f {staged_quoted} \"$HOME\"/{}",
            shell_quote(relative_path)
        )))
        .await?
        .check()?;
    Ok(InstallAction::Upgraded)
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
    let probe = probe(connection).await?;
    HostPlatform::from_uname(&probe.os, &probe.arch).ok_or_else(|| {
        SshError::Bootstrap(format!("unsupported platform {} {}", probe.os, probe.arch))
    })
}

async fn probe(connection: &Connection) -> Result<Probe, SshError> {
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
    let output = connection.exec(&sh_command(&script)).await?.check()?;
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
/// to a note (`--no-ask-password`: never prompt). Returns whether lingering is now on.
async fn enable_linger(connection: &Connection) -> Result<bool, SshError> {
    let output = connection
        .exec(&sh_command(
            "loginctl --no-ask-password enable-linger \"$(id -un)\" >/dev/null 2>&1; \
             loginctl show-user \"$(id -un)\" -p Linger --value 2>/dev/null",
        ))
        .await?;
    let enabled = output.stdout_text().trim() == "yes";
    tracing::info!(enabled, "enabling lingering");
    Ok(enabled)
}

#[cfg(test)]
mod tests {
    use super::*;

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
