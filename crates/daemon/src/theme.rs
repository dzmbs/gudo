//! What programs in panes learn about their terminal: its name and features from the
//! environment and from queries, and the colors of the theme it shows.
//!
//! A pane's terminal is libghostty-vt, so it supports what Ghostty supports and answers
//! queries as Ghostty does. Programs that decide what to draw from a list of terminal names
//! (Claude Code's progress bar and images, Codex's pets and notifications) only enable those
//! features for `TERM_PROGRAM=ghostty` or an XTVERSION naming Ghostty, so panes say exactly
//! that, as other terminals built on Ghostty do. `LC_TERMINAL` and the XTVERSION suffix name
//! the product for whoever wants to tell it apart.
//!
//! Colors: each pane answers color queries (OSC 4, 10, 11, 12, `CSI ? 996 n`) with the theme
//! of the device that last focused or typed into it, or else the theme announced last; until
//! a device sends one, Ghostty's default theme.

use std::collections::HashMap;
use std::ffi::OsString;
use std::process::Command;
use std::sync::{Arc, Mutex};

use ghostty_vt::{DefaultColors, Identity, Rgb};
use proto::TerminalColors;

use crate::core::{ConnId, lock};

/// `TERM` in panes: every host has its terminfo entry, also across SSH.
pub(crate) const TERM: &str = "xterm-256color";

/// Variables a pane's program must not inherit from the terminal the daemon was started in:
/// they would name another terminal or a multiplexer the pane is not inside.
const INHERITED_TERMINAL_VARS: &[&str] = &[
    "TMUX",
    "TMUX_PANE",
    "STY",
    "ZELLIJ",
    "ZELLIJ_SESSION_NAME",
    "ZELLIJ_PANE_ID",
    "ZELLIJ_VERSION",
    "KITTY_WINDOW_ID",
    "KITTY_PID",
    "KITTY_LISTEN_ON",
    "KITTY_PUBLIC_KEY",
    "KITTY_INSTALLATION_DIR",
    "ITERM_SESSION_ID",
    "ITERM_PROFILE",
    "ITERM_PROFILE_NAME",
    "WEZTERM_EXECUTABLE",
    "WEZTERM_PANE",
    "WEZTERM_UNIX_SOCKET",
    "WEZTERM_VERSION",
    "WT_SESSION",
    "WT_PROFILE_ID",
    "VTE_VERSION",
    "KONSOLE_VERSION",
    "GNOME_TERMINAL_SCREEN",
    "ALACRITTY_SOCKET",
    "ALACRITTY_WINDOW_ID",
    "ALACRITTY_LOG",
    "GHOSTTY_RESOURCES_DIR",
    "TERMINAL_EMULATOR",
    "TERM_SESSION_ID",
    "LC_TERMINAL_VERSION",
    "VSCODE_INJECTION",
];

/// The XTVERSION reply and terminfo name of every pane's terminal.
pub(crate) fn identity() -> Identity {
    Identity {
        xtversion: format!(
            "ghostty {} ({})",
            ghostty_vt::GHOSTTY_VERSION,
            brand::PRODUCT_NAME
        ),
        terminfo: TERM.into(),
    }
}

/// The terminal environment of a pane's program.
pub(crate) fn pane_env() -> [(&'static str, String); 5] {
    [
        ("TERM", TERM.into()),
        ("COLORTERM", "truecolor".into()),
        ("TERM_PROGRAM", "ghostty".into()),
        ("TERM_PROGRAM_VERSION", ghostty_vt::GHOSTTY_VERSION.into()),
        ("LC_TERMINAL", brand::PRODUCT_NAME.into()),
    ]
}

/// Gives `command` the pane terminal environment, without what it inherited from another one.
pub(crate) fn apply_pane_env(command: &mut Command) {
    for key in INHERITED_TERMINAL_VARS {
        command.env_remove(key);
    }
    for (key, value) in pane_env() {
        command.env(key, OsString::from(value));
    }
}

/// The colors a client's theme gives panes.
pub(crate) fn default_colors(colors: &TerminalColors) -> Option<DefaultColors> {
    let rgb = |[r, g, b]: [u8; 3]| Rgb::new(r, g, b);
    let palette = match colors.palette.len() {
        0 => None,
        256 => {
            let mut palette = Box::new([Rgb::default(); 256]);
            for (slot, color) in palette.iter_mut().zip(&colors.palette) {
                *slot = rgb(*color);
            }
            Some(palette)
        }
        _ => return None,
    };
    Some(DefaultColors {
        foreground: rgb(colors.foreground),
        background: rgb(colors.background),
        cursor: colors.cursor.map(rgb),
        palette,
    })
}

/// The themes clients announced, and which one each pane shows.
#[derive(Default)]
pub(crate) struct Themes {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    by_conn: HashMap<ConnId, Arc<DefaultColors>>,
    latest: Option<Arc<DefaultColors>>,
}

impl Themes {
    /// The theme a new pane starts with.
    pub fn current(&self) -> Arc<DefaultColors> {
        lock(&self.state).latest.clone().unwrap_or_default()
    }

    /// Records `conn`'s theme, which becomes the latest when `latest`. Returns it.
    pub fn announce(
        &self,
        conn: ConnId,
        colors: DefaultColors,
        latest: bool,
    ) -> Arc<DefaultColors> {
        let colors = Arc::new(colors);
        let mut state = lock(&self.state);
        state.by_conn.insert(conn, Arc::clone(&colors));
        if latest {
            state.latest = Some(Arc::clone(&colors));
        }
        colors
    }

    /// `conn`'s theme, if it sent one.
    pub fn of(&self, conn: ConnId) -> Option<Arc<DefaultColors>> {
        lock(&self.state).by_conn.get(&conn).cloned()
    }

    /// Forgets a connection that left. Panes keep the theme they show.
    pub fn forget(&self, conn: ConnId) {
        lock(&self.state).by_conn.remove(&conn);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_palette_must_be_complete() {
        let mut colors = TerminalColors {
            foreground: [1, 2, 3],
            background: [4, 5, 6],
            cursor: None,
            palette: vec![[0, 0, 0]; 16],
        };
        assert!(default_colors(&colors).is_none());
        colors.palette = vec![[7, 8, 9]; 256];
        let converted = default_colors(&colors).unwrap();
        assert_eq!(converted.palette.unwrap()[255], Rgb::new(7, 8, 9));
        colors.palette.clear();
        assert_eq!(
            default_colors(&colors).unwrap().background,
            Rgb::new(4, 5, 6)
        );
    }

    #[test]
    fn panes_name_ghostty_and_the_product() {
        let env: HashMap<_, _> = pane_env().into_iter().collect();
        assert_eq!(env["TERM"], "xterm-256color");
        assert_eq!(env["COLORTERM"], "truecolor");
        assert_eq!(env["TERM_PROGRAM"], "ghostty");
        assert_eq!(env["TERM_PROGRAM_VERSION"], ghostty_vt::GHOSTTY_VERSION);
        assert_eq!(env["LC_TERMINAL"], brand::PRODUCT_NAME);
        assert!(identity().xtversion.starts_with("ghostty "));
    }
}
