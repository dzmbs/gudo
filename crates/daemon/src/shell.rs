//! Automatic shell integration for the shells the daemon starts, the way Ghostty does it
//! (`vendor/ghostty/src/termio/shell_integration.zig`), without touching the user's dotfiles.
//!
//! Ghostty's scripts (`vendor/ghostty/src/shell-integration`) are written to
//! `<state>/shell-integration/` on start, unmodified except for `ghostty.bash`'s directory
//! title (see `BASH_DIRECTORY_TITLE`), and each shell is pointed at them:
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
//! so); fish's and `bash-preexec.sh` are MIT. They are shipped as separate files executed by the
//! shell, as Ghostty ships them; the modified `ghostty.bash` says so in its header.

use std::borrow::Cow;
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
        BASH_SCRIPT,
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

const BASH_SCRIPT: &str = "bash/ghostty.bash";

/// `(vendored text, replacement)` edits to `ghostty.bash`. Its directory title is `\w` in `PS1`,
/// which prints the directory's control bytes as they are: a directory named with BEL and ESC
/// could end the title and send a sequence of its own (an OSC 52 clipboard write). The title is
/// printed at each prompt from `$PWD` without them instead, with `~` for home as `\w` shows it.
/// GPL-3.0 asks a modified copy to say so in the file.
const BASH_DIRECTORY_TITLE: [(&str, &str); 3] = [
    (
        "# We need to be in interactive mode to proceed.\n",
        "# This copy is modified (November 2026): the working-directory title is printed from\n\
         # $PWD without control bytes, instead of with \\w in PS1.\n\
         \n\
         # We need to be in interactive mode to proceed.\n",
    ),
    (
        "\n    # Title (working directory)\n    \
         if [[ \"$GHOSTTY_SHELL_FEATURES\" == *\"title\"* ]]; then\n      \
         PS1=$PS1'\\[\\e]2;\\w\\a\\]'\n    \
         fi\n",
        "",
    ),
    (
        "\n  _ghostty_executing=0\n}\n",
        r#"
  if [[ "$GHOSTTY_SHELL_FEATURES" == *"title"* ]]; then
    builtin local title_directory="${PWD//[[:cntrl:]]/}"
    if [[ -n "$HOME" && "$HOME" != / ]] &&
      [[ "$title_directory" == "$HOME" || "$title_directory" == "$HOME"/* ]]; then
      title_directory="~${title_directory#"$HOME"}"
    fi
    builtin printf "\e]2;%s\a" "$title_directory"
  fi

  _ghostty_executing=0
}
"#,
    ),
];

/// A script as it is installed: the vendored file, with `ghostty.bash`'s directory title made
/// safe.
fn installed_contents(relative: &str, vendored: &'static str) -> Cow<'static, str> {
    if relative != BASH_SCRIPT {
        return Cow::Borrowed(vendored);
    }
    let mut script = vendored.to_owned();
    for (vendored_text, replacement) in BASH_DIRECTORY_TITLE {
        script = script.replacen(vendored_text, replacement, 1);
    }
    Cow::Owned(script)
}

/// Features the scripts enable: a blinking bar cursor at the prompt and titles from the
/// running command and directory; `path` too when the CLI is linked. `sudo` and `ssh-*` need
/// the Ghostty binary and terminfo, which hosts don't have.
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
    /// Appended to `PATH` after the shell's startup files (Ghostty's `path` feature), which
    /// often set `PATH` from scratch.
    bin_dir: Option<PathBuf>,
}

impl ShellIntegration {
    /// Writes the scripts under `<state_dir>/shell-integration`, replacing stale copies.
    pub fn install(state_dir: &Path) -> io::Result<Self> {
        let dir = state_dir.join("shell-integration");
        for (relative, vendored) in FILES {
            let contents = installed_contents(relative, vendored);
            let path = dir.join(relative);
            if std::fs::read(&path).is_ok_and(|old| old == contents.as_bytes()) {
                continue;
            }
            fsutil::write_atomic(&path, contents.as_bytes())?;
        }
        Ok(Self { dir, bin_dir: None })
    }

    /// Links `<state_dir>/bin/<CLI_BIN>` to `exe` and adds that directory to panes' `PATH`.
    pub fn link_cli(&mut self, state_dir: &Path, exe: &Path) -> io::Result<()> {
        let bin_dir = state_dir.join("bin");
        std::fs::create_dir_all(&bin_dir)?;
        let link = bin_dir.join(brand::CLI_BIN);
        if std::fs::read_link(&link).ok().as_deref() != Some(exe) {
            let staged = bin_dir.join(format!(".{}.new", brand::CLI_BIN));
            let _ = std::fs::remove_file(&staged);
            std::os::unix::fs::symlink(exe, &staged)?;
            std::fs::rename(&staged, &link)?;
        }
        self.bin_dir = Some(bin_dir);
        Ok(())
    }

    /// `PATH` for a pane: `path` with the CLI's directory at the end, if it is not there.
    pub fn pane_path(&self, path: Option<OsString>) -> Option<OsString> {
        let bin_dir = self.bin_dir.as_ref()?;
        let mut parts: Vec<PathBuf> = path
            .as_deref()
            .map(|path| std::env::split_paths(path).collect())
            .unwrap_or_default();
        if parts.contains(bin_dir) {
            return path;
        }
        parts.push(bin_dir.clone());
        std::env::join_paths(parts).ok()
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
        match &self.bin_dir {
            Some(bin_dir) => {
                injection
                    .env
                    .push(("GHOSTTY_SHELL_FEATURES".into(), format!("{FEATURES},path")));
                injection.env.push((
                    "GHOSTTY_BIN_DIR".into(),
                    bin_dir.to_string_lossy().into_owned(),
                ));
            }
            None => injection
                .env
                .push(("GHOSTTY_SHELL_FEATURES".into(), FEATURES.into())),
        }
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
                injection.env.push(("ENV".into(), path(BASH_SCRIPT)));
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
        let bash_script =
            std::fs::read_to_string(dir.path().join("shell-integration").join(BASH_SCRIPT))
                .unwrap();
        let vendored_bash_script = FILES
            .iter()
            .find(|(relative, _)| *relative == BASH_SCRIPT)
            .unwrap()
            .1;
        for (vendored_text, replacement) in BASH_DIRECTORY_TITLE {
            assert_eq!(
                vendored_bash_script.matches(vendored_text).count(),
                1,
                "{vendored_text}"
            );
            assert!(bash_script.contains(replacement), "{replacement}");
        }
        assert!(!bash_script.contains(r"\w\a"));
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

    /// Any bash runs the script: before 4.4 it takes the `bash-preexec.sh` path, so macOS's
    /// `/bin/bash` covers the title and directory code too.
    #[test]
    fn bash_directory_names_cannot_inject_sequences() {
        let Some(bash) = ["/bin/bash", "/usr/bin/bash"]
            .into_iter()
            .map(Path::new)
            .find(|path| path.exists())
        else {
            return;
        };
        let state = tempfile::tempdir().unwrap();
        ShellIntegration::install(state.path()).unwrap();
        let home = tempfile::tempdir().unwrap();
        let home_path = home.path().canonicalize().unwrap();
        for name in [
            "x\x07\x1b]52;c;aW5qZWN0ZWQ=\x07y",
            r"x\a\e]52;c;aW5qZWN0ZWQ=\ay",
        ] {
            std::fs::create_dir_all(home_path.join(name)).unwrap();
        }
        let commands = home_path.join("commands");
        std::fs::write(
            &commands,
            "cd \"$(printf 'x\\007\\033]52;c;aW5qZWN0ZWQ=\\007y')\"\ncd ..\n\
             cd 'x\\a\\e]52;c;aW5qZWN0ZWQ=\\ay'\necho DONE\n",
        )
        .unwrap();
        let output = std::process::Command::new(bash)
            .args(["--noprofile", "--rcfile"])
            .arg(state.path().join("shell-integration/bash/ghostty.bash"))
            .arg("-i")
            .env_clear()
            .env("HOME", &home_path)
            .env("PATH", "/usr/bin:/bin")
            .env("PS1", "$ ")
            .env("GHOSTTY_SHELL_FEATURES", FEATURES)
            .current_dir(&home_path)
            .stdin(std::fs::File::open(&commands).unwrap())
            .output()
            .unwrap();
        let printed = [output.stdout, output.stderr].concat();
        let shown = String::from_utf8_lossy(&printed);
        assert!(shown.contains("DONE"), "{shown:?}");
        assert!(
            shown.contains("\x1b]2;~/x]52;c;aW5qZWN0ZWQ=y\x07"),
            "{shown:?}"
        );
        assert!(
            shown.contains("\x1b]2;~/x\\a\\e]52;c;aW5qZWN0ZWQ=\\ay\x07"),
            "{shown:?}"
        );
        assert!(!shown.contains("\x1b]52"), "{shown:?}");
    }

    #[test]
    fn panes_find_the_cli_after_their_startup_files() {
        let dir = tempfile::tempdir().unwrap();
        let mut integration = ShellIntegration::install(dir.path()).unwrap();
        assert_eq!(integration.pane_path(Some("/usr/bin".into())), None);
        let features = |integration: &ShellIntegration| {
            integration
                .injection(Path::new("/bin/zsh"), |_| None)
                .unwrap()
                .env
                .into_iter()
                .find(|(name, _)| name == "GHOSTTY_SHELL_FEATURES")
                .unwrap()
                .1
        };
        assert!(!features(&integration).contains("path"));

        let exe = dir.path().join("hostd");
        std::fs::write(&exe, b"").unwrap();
        integration.link_cli(dir.path(), &exe).unwrap();
        integration.link_cli(dir.path(), &exe).unwrap();
        let bin_dir = dir.path().join("bin");
        assert_eq!(
            std::fs::read_link(bin_dir.join(brand::CLI_BIN)).unwrap(),
            exe
        );
        assert!(features(&integration).ends_with(",path"));
        let zsh = integration
            .injection(Path::new("/bin/zsh"), |_| None)
            .unwrap();
        assert!(
            zsh.env
                .contains(&("GHOSTTY_BIN_DIR".into(), bin_dir.to_string_lossy().into()))
        );

        let path = integration.pane_path(Some("/usr/bin:/bin".into())).unwrap();
        assert_eq!(
            path,
            OsString::from(format!("/usr/bin:/bin:{}", bin_dir.display()))
        );
        assert_eq!(integration.pane_path(Some(path.clone())), Some(path));
    }
}
