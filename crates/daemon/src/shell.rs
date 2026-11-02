//! Automatic shell integration for the shells the daemon starts, the way Ghostty does it
//! (`vendor/ghostty/src/termio/shell_integration.zig`), without touching the user's dotfiles.
//!
//! Ghostty's scripts (`vendor/ghostty/src/shell-integration`) are written to
//! `<state>/shell-integration/` on start, unmodified, and each shell is pointed at them:
//!
//! - **zsh**: `ZDOTDIR` names our directory; its `.zshenv` restores the user's `ZDOTDIR`
//!   (kept in `GHOSTTY_ZSH_ZDOTDIR`), sources the user's `.zshenv` and loads the integration.
//! - **bash** (4.4+; not macOS's `/bin/bash` 3.2): started with `--posix` and `ENV` naming
//!   `ghostty.bash`, which leaves POSIX mode and sources the usual startup files itself.
//! - **fish**: our directory is prepended to `XDG_DATA_DIRS`, so fish loads
//!   `fish/vendor_conf.d/ghostty-shell-integration.fish`, which removes it again.
//!
//! The scripts emit OSC 133 prompt/command marks (with exit status) and OSC 7 working
//! directories; libghostty-vt parses them in the pane's terminal.
//!
//! Licensing: the zsh and bash scripts derive from kitty's and are GPL-3.0 (their headers say
//! so); fish's and `bash-preexec.sh` are MIT. They are shipped as separate, unmodified files
//! executed by the shell, as Ghostty ships them.

use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

use crate::fsutil;

/// `(path under the integration directory, contents)`.
const FILES: &[(&str, &str)] = &[
    (
        "zsh/.zshenv",
        include_str!("../../../vendor/ghostty/src/shell-integration/zsh/.zshenv"),
    ),
    (
        "zsh/ghostty-integration",
        include_str!("../../../vendor/ghostty/src/shell-integration/zsh/ghostty-integration"),
    ),
    (
        "bash/ghostty.bash",
        include_str!("../../../vendor/ghostty/src/shell-integration/bash/ghostty.bash"),
    ),
    (
        "bash/bash-preexec.sh",
        include_str!("../../../vendor/ghostty/src/shell-integration/bash/bash-preexec.sh"),
    ),
    (
        "fish/vendor_conf.d/ghostty-shell-integration.fish",
        include_str!(
            "../../../vendor/ghostty/src/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish"
        ),
    ),
];

/// Features the scripts enable: a blinking bar cursor at the prompt and titles from the
/// running command and directory. `sudo`, `ssh-*` and `path` need the Ghostty binary and
/// terminfo, which hosts don't have.
const FEATURES: &str = "cursor:blink,title";

/// A shell Ghostty's scripts integrate with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Shell {
    Bash,
    Zsh,
    Fish,
}

impl Shell {
    /// Recognises `shell` by its file name, as Ghostty does. macOS's `/bin/bash` (3.2) has no
    /// automatic integration.
    pub fn detect(shell: &Path) -> Option<Self> {
        let name = shell.file_name()?.to_str()?;
        match name.strip_prefix('-').unwrap_or(name) {
            "bash" if cfg!(target_os = "macos") && shell == Path::new("/bin/bash") => None,
            "bash" => Some(Self::Bash),
            "zsh" => Some(Self::Zsh),
            "fish" => Some(Self::Fish),
            _ => None,
        }
    }
}

/// What starting a shell with integration needs.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Injection {
    pub env: Vec<(String, String)>,
    /// Arguments that go before the shell's own (`--posix` for bash).
    pub args: Vec<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct ShellIntegration {
    dir: PathBuf,
}

impl ShellIntegration {
    /// Writes the scripts under `<state_dir>/shell-integration`, replacing stale copies.
    pub fn install(state_dir: &Path) -> io::Result<Self> {
        let dir = state_dir.join("shell-integration");
        for (relative, contents) in FILES {
            let path = dir.join(relative);
            if std::fs::read(&path).is_ok_and(|old| old == contents.as_bytes()) {
                continue;
            }
            fsutil::write_atomic(&path, contents.as_bytes())?;
        }
        Ok(Self { dir })
    }

    /// The injection for `shell`, given the environment the pane would otherwise get
    /// (`lookup` answers for a variable name). `None` for shells without integration.
    pub fn injection(
        &self,
        shell: &Path,
        lookup: impl Fn(&str) -> Option<OsString>,
    ) -> Option<Injection> {
        let kind = Shell::detect(shell)?;
        let path = |relative: &str| self.dir.join(relative).to_string_lossy().into_owned();
        let existing = |name: &str| lookup(name).map(|value| value.to_string_lossy().into_owned());
        let mut injection = Injection::default();
        injection
            .env
            .push(("GHOSTTY_SHELL_FEATURES".into(), FEATURES.into()));
        match kind {
            Shell::Zsh => {
                if let Some(old) = existing("ZDOTDIR") {
                    injection.env.push(("GHOSTTY_ZSH_ZDOTDIR".into(), old));
                }
                injection.env.push(("ZDOTDIR".into(), path("zsh")));
            }
            Shell::Bash => {
                injection.args.push("--posix".into());
                if let Some(old) = existing("ENV").filter(|value| !value.is_empty()) {
                    injection.env.push(("GHOSTTY_BASH_ENV".into(), old));
                }
                injection
                    .env
                    .push(("ENV".into(), path("bash/ghostty.bash")));
                injection
                    .env
                    .push(("GHOSTTY_BASH_INJECT".into(), "1".into()));
                if existing("HISTFILE").is_none()
                    && let Some(home) = existing("HOME")
                {
                    injection
                        .env
                        .push(("HISTFILE".into(), format!("{home}/.bash_history")));
                    injection
                        .env
                        .push(("GHOSTTY_BASH_UNEXPORT_HISTFILE".into(), "1".into()));
                }
            }
            Shell::Fish => {
                let ours = self.dir.to_string_lossy().into_owned();
                let rest = existing("XDG_DATA_DIRS")
                    .filter(|value| !value.is_empty())
                    .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
                injection
                    .env
                    .push(("GHOSTTY_SHELL_INTEGRATION_XDG_DIR".into(), ours.clone()));
                injection
                    .env
                    .push(("XDG_DATA_DIRS".into(), format!("{ours}:{rest}")));
            }
        }
        Some(injection)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_shells_like_ghostty() {
        assert_eq!(Shell::detect(Path::new("/usr/bin/zsh")), Some(Shell::Zsh));
        assert_eq!(Shell::detect(Path::new("fish")), Some(Shell::Fish));
        assert_eq!(Shell::detect(Path::new("/bin/sh")), None);
        let bin_bash = Shell::detect(Path::new("/bin/bash"));
        assert_eq!(bin_bash.is_none(), cfg!(target_os = "macos"));
        assert_eq!(
            Shell::detect(Path::new("/opt/homebrew/bin/bash")),
            Some(Shell::Bash)
        );
    }

    #[test]
    fn installs_scripts_and_builds_injections() {
        let dir = tempfile::tempdir().unwrap();
        let integration = ShellIntegration::install(dir.path()).unwrap();
        let zshenv = dir.path().join("shell-integration/zsh/.zshenv");
        assert!(
            std::fs::read_to_string(&zshenv)
                .unwrap()
                .contains("GHOSTTY_ZSH_ZDOTDIR")
        );
        // Installing again keeps the files.
        ShellIntegration::install(dir.path()).unwrap();

        let env = |name: &str| match name {
            "ZDOTDIR" => Some("/home/u/.zsh".into()),
            "HOME" => Some("/home/u".into()),
            "ENV" => Some("/home/u/.shrc".into()),
            _ => None,
        };
        let zsh = integration.injection(Path::new("/bin/zsh"), env).unwrap();
        assert!(
            zsh.env
                .contains(&("GHOSTTY_ZSH_ZDOTDIR".into(), "/home/u/.zsh".into()))
        );
        assert!(
            zsh.env
                .iter()
                .any(|(name, value)| name == "ZDOTDIR" && value.ends_with("zsh"))
        );

        let bash = integration
            .injection(Path::new("/usr/bin/bash-5/bash"), env)
            .unwrap();
        assert_eq!(bash.args, ["--posix"]);
        assert!(
            bash.env
                .contains(&("GHOSTTY_BASH_ENV".into(), "/home/u/.shrc".into()))
        );
        assert!(
            bash.env
                .contains(&("HISTFILE".into(), "/home/u/.bash_history".into()))
        );

        let fish = integration
            .injection(Path::new("/usr/bin/fish"), |_| None)
            .unwrap();
        let xdg = &fish
            .env
            .iter()
            .find(|(name, _)| name == "XDG_DATA_DIRS")
            .unwrap()
            .1;
        assert!(xdg.ends_with(":/usr/local/share:/usr/share"), "{xdg}");
        assert!(integration.injection(Path::new("/bin/sh"), env).is_none());
    }
}
