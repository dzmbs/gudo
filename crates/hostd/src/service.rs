//! Per-user service installation: a systemd user unit on Linux, a LaunchAgent on macOS.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("$HOME is not set")
}

fn exe() -> Result<PathBuf> {
    std::env::current_exe()?
        .canonicalize()
        .context("locating this executable")
}

fn run(cmd: &mut Command) -> Result<()> {
    let status = cmd.status().with_context(|| format!("running {cmd:?}"))?;
    if !status.success() {
        bail!("{cmd:?} failed with {status}");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn unit_path() -> Result<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .map_or_else(|| home().map(|h| h.join(".config")), Ok)?;
    Ok(config
        .join("systemd/user")
        .join(format!("{}.service", brand::DAEMON_BIN)))
}

/// Installs and (re)starts the service.
#[cfg(target_os = "linux")]
pub fn install(state_dir: &Path) -> Result<()> {
    let path = unit_path()?;
    let unit = format!(
        "[Unit]\n\
         Description={name} terminal and coding-agent host daemon\n\
         After=network-online.target\n\
         Wants=network-online.target\n\n\
         [Service]\n\
         ExecStart={exe} --state-dir {state} run\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         # Panes are children of the daemon; stopping it ends them (the layout is restored on\n\
         # the next start and agents resume their sessions).\n\
         KillMode=control-group\n\n\
         [Install]\n\
         WantedBy=default.target\n",
        name = brand::PRODUCT_NAME,
        exe = exe()?.display(),
        state = state_dir.display(),
    );
    std::fs::create_dir_all(path.parent().expect("unit path has a parent"))?;
    std::fs::write(&path, unit)?;
    run(Command::new("systemctl").args(["--user", "daemon-reload"]))?;
    let unit = format!("{}.service", brand::DAEMON_BIN);
    run(Command::new("systemctl").args(["--user", "enable", &unit]))?;
    // Restart rather than start, so reinstalling over a new binary (an upgrade) runs it.
    run(Command::new("systemctl").args(["--user", "restart", &unit]))?;
    println!("installed {}", path.display());
    println!(
        "To keep it running after you log out (and start it at boot on a server), run once:\n  \
         sudo loginctl enable-linger \"$USER\""
    );
    println!("Logs: journalctl --user -u {} -f", brand::DAEMON_BIN);
    Ok(())
}

/// Stops and removes the service.
#[cfg(target_os = "linux")]
pub fn uninstall() -> Result<()> {
    let unit = format!("{}.service", brand::DAEMON_BIN);
    let _ = run(Command::new("systemctl").args(["--user", "disable", "--now", &unit]));
    let path = unit_path()?;
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    let _ = run(Command::new("systemctl").args(["--user", "daemon-reload"]));
    println!("removed {}", path.display());
    Ok(())
}

#[cfg(target_os = "macos")]
fn plist_path() -> Result<PathBuf> {
    Ok(home()?
        .join("Library/LaunchAgents")
        .join(format!("{}.plist", brand::SERVICE_LABEL)))
}

#[cfg(target_os = "macos")]
fn gui_domain() -> String {
    // SAFETY: getuid never fails.
    format!("gui/{}", unsafe { libc::getuid() })
}

/// Installs and starts the LaunchAgent.
#[cfg(target_os = "macos")]
pub fn install(state_dir: &Path) -> Result<()> {
    let path = plist_path()?;
    let logs = home()?.join("Library/Logs").join(brand::DIR_NAME);
    std::fs::create_dir_all(&logs)?;
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{exe}</string>
    <string>--state-dir</string>
    <string>{state}</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>{logs}/hostd.log</string>
</dict>
</plist>
"#,
        label = brand::SERVICE_LABEL,
        exe = exe()?.display(),
        state = state_dir.display(),
        logs = logs.display(),
    );
    std::fs::create_dir_all(path.parent().expect("plist path has a parent"))?;
    std::fs::write(&path, plist)?;
    let domain = gui_domain();
    let _ = Command::new("launchctl")
        .args(["bootout", &format!("{domain}/{}", brand::SERVICE_LABEL)])
        .status();
    run(Command::new("launchctl").args(["bootstrap", &domain, &path.to_string_lossy()]))?;
    println!("installed {}", path.display());
    println!("Logs: {}/hostd.log", logs.display());
    Ok(())
}

/// Stops and removes the LaunchAgent.
#[cfg(target_os = "macos")]
pub fn uninstall() -> Result<()> {
    let path = plist_path()?;
    let _ = Command::new("launchctl")
        .args([
            "bootout",
            &format!("{}/{}", gui_domain(), brand::SERVICE_LABEL),
        ])
        .status();
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    println!("removed {}", path.display());
    Ok(())
}
