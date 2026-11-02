//! Window size and line-discipline facts read through the PTY master.

use std::io;
use std::os::fd::AsFd;

use rustix::termios::{self, LocalModes, Winsize};

/// Terminal dimensions in cells, plus optional pixel dimensions for image protocols.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct WinSize {
    pub rows: u16,
    pub cols: u16,
    /// Total width in pixels, or 0 if unknown.
    pub pixel_width: u16,
    /// Total height in pixels, or 0 if unknown.
    pub pixel_height: u16,
}

impl WinSize {
    /// Creates a size in cells with unknown pixel dimensions.
    ///
    /// # Examples
    ///
    /// ```
    /// let size = pty::WinSize::new(24, 80);
    /// assert_eq!((size.rows, size.cols), (24, 80));
    /// ```
    pub const fn new(rows: u16, cols: u16) -> Self {
        Self {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        }
    }
}

impl From<WinSize> for Winsize {
    fn from(size: WinSize) -> Self {
        Winsize {
            ws_row: size.rows,
            ws_col: size.cols,
            ws_xpixel: size.pixel_width,
            ws_ypixel: size.pixel_height,
        }
    }
}

/// Applies `size` with `TIOCSWINSZ`; the kernel then sends `SIGWINCH` to the foreground group.
pub(crate) fn set_size(fd: impl AsFd, size: WinSize) -> io::Result<()> {
    Ok(termios::tcsetwinsize(fd, size.into())?)
}

/// The slave's line-discipline flags that matter for local echo prediction.
///
/// Read with `tcgetattr` on the master. On both macOS and Linux this returns the slave's
/// termios.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct EchoState {
    /// `ECHO`: the kernel echoes typed characters. Off at password prompts and in most
    /// full-screen programs, which draw input themselves.
    pub echo: bool,
    /// `ICANON`: line-buffered (cooked) input with kernel line editing. Off in raw-mode line
    /// editors (zsh ZLE, readline, fish) and TUIs.
    pub canonical: bool,
}

impl EchoState {
    /// Returns `true` for the classic hidden-input shape (`read -s`, `sudo`, `ssh` password
    /// prompts): cooked input with echo off. A client must never predict here.
    pub fn is_hidden_input(self) -> bool {
        !self.echo && self.canonical
    }

    pub(crate) fn read(fd: impl AsFd) -> io::Result<Self> {
        let modes = termios::tcgetattr(fd)?.local_modes;
        Ok(Self {
            echo: modes.contains(LocalModes::ECHO),
            canonical: modes.contains(LocalModes::ICANON),
        })
    }
}

impl Default for EchoState {
    /// A fresh PTY's line discipline: cooked with echo.
    fn default() -> Self {
        Self {
            echo: true,
            canonical: true,
        }
    }
}
