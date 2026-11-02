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

/// `path` as one quoted systemd `ExecStart` word: spaces, quotes, `%` specifiers and `$`
/// expansion would otherwise change the command.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn systemd_word(path: &Path) -> Result<String> {
    let s = path.to_str().context("the path is not UTF-8")?;
    if s.chars().any(char::is_control) {
        bail!("{s:?} has control characters");
    }
    let escaped = s
        .replace('\\', r"\\")
        .replace('"', "\\\"")
        .replace('%', "%%")
        .replace('$', "$$");
    Ok(format!("\"{escaped}\""))
}

/// `path` as XML text for the property list.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn xml_text(path: &Path) -> String {
    path.to_string_lossy()
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn run(cmd: &mut Command) -> Result<()> {
    let status = cmd.status().with_context(|| format!("running {cmd:?}"))?;
    if !status.success() {
        bail!("{cmd:?} failed with {status}");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn unit_dir() -> Result<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .map_or_else(|| home().map(|h| h.join(".config")), Ok)?;
    Ok(config.join("systemd/user"))
}

#[cfg(target_os = "linux")]
fn unit_path() -> Result<PathBuf> {
    Ok(unit_dir()?.join(format!("{}.service", brand::DAEMON_BIN)))
}

#[cfg(target_os = "linux")]
fn legacy_unit() -> String {
    format!("{}.service", brand::legacy::DAEMON_BIN)
}

/// Whether the service installed under the product's earlier name is still there.
#[cfg(target_os = "linux")]
pub fn legacy_installed() -> bool {
    unit_dir().is_ok_and(|dir| dir.join(legacy_unit()).exists())
}

/// Stops and removes the service installed under the product's earlier name. The file goes
/// first: stopping it ends this process too when it runs as that service.
#[cfg(target_os = "linux")]
fn retire_legacy() -> Result<()> {
    let path = unit_dir()?.join(legacy_unit());
    if !path.exists() {
        return Ok(());
    }
    let unit = legacy_unit();
    let _ = run(Command::new("systemctl").args(["--user", "disable", &unit]));
    std::fs::remove_file(&path)?;
    let _ = run(Command::new("systemctl").args(["--user", "daemon-reload"]));
    let _ = run(Command::new("systemctl").args(["--user", "stop", &unit]));
    Ok(())
}

/// Installs and (re)starts the service, replacing one installed under the earlier name.
pub fn install(state_dir: &Path) -> Result<()> {
    retire_legacy()?;
    install_exe(&exe()?, state_dir)
}

/// Run by a daemon upgraded in place under the earlier name's service: starts the service
/// for `exe` (the same build under today's name), then stops the old one, ending this process.
pub fn hand_over(exe: &Path, state_dir: &Path) -> Result<()> {
    install_exe(exe, state_dir)?;
    retire_legacy()
}

#[cfg(target_os = "linux")]
fn install_exe(exe: &Path, state_dir: &Path) -> Result<()> {
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
        exe = systemd_word(exe)?,
        state = systemd_word(state_dir)?,
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
fn plist_path_for(label: &str) -> Result<PathBuf> {
    Ok(home()?
        .join("Library/LaunchAgents")
        .join(format!("{label}.plist")))
}

#[cfg(target_os = "macos")]
fn plist_path() -> Result<PathBuf> {
    plist_path_for(brand::SERVICE_LABEL)
}

#[cfg(target_os = "macos")]
fn gui_domain() -> String {
    // SAFETY: getuid never fails.
    format!("gui/{}", unsafe { libc::getuid() })
}

/// Whether the LaunchAgent installed under the product's earlier name is still there.
#[cfg(target_os = "macos")]
pub fn legacy_installed() -> bool {
    plist_path_for(brand::legacy::SERVICE_LABEL).is_ok_and(|p| p.exists())
}

/// Stops and removes the LaunchAgent installed under the product's earlier name. The file
/// goes first: stopping it ends this process too when it runs as that agent.
#[cfg(target_os = "macos")]
fn retire_legacy() -> Result<()> {
    let path = plist_path_for(brand::legacy::SERVICE_LABEL)?;
    if !path.exists() {
        return Ok(());
    }
    std::fs::remove_file(&path)?;
    let _ = Command::new("launchctl")
        .args([
            "bootout",
            &format!("{}/{}", gui_domain(), brand::legacy::SERVICE_LABEL),
        ])
        .status();
    Ok(())
}

#[cfg(target_os = "macos")]
fn install_exe(exe: &Path, state_dir: &Path) -> Result<()> {
    let path = plist_path()?;
    let logs = home()?.join("Library/Logs").join(brand::MAC_DIR_NAME);
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
        exe = xml_text(exe),
        state = xml_text(state_dir),
        logs = xml_text(&logs),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unit_paths_stay_one_literal_word() {
        assert_eq!(
            systemd_word(Path::new("/home/a b/bin/gudo")).unwrap(),
            r#""/home/a b/bin/gudo""#
        );
        assert_eq!(
            systemd_word(Path::new(r#"/x/%h$HOME"q\"#)).unwrap(),
            r#""/x/%%h$$HOME\"q\\""#
        );
        assert!(systemd_word(Path::new("/x\nExecStartPre=/bin/evil")).is_err());
    }

    #[test]
    fn plist_paths_are_xml_text() {
        assert_eq!(
            xml_text(Path::new("/Users/a&b/<x>")),
            "/Users/a&amp;b/&lt;x&gt;"
        );
    }
}
