//! `un-hook open-url <url>…`: the panes' `BROWSER`. Each URL goes to the app showing the pane
//! (a sign-in page opens in a system sign-in sheet there, anything else in its browser). With
//! no app to take it, the system's own opener runs when there is a display; else it fails, so
//! the program prints its URL instead.

use std::process::{Command, Stdio};

use daemon::{BrowserAsk, BrowserReply};

use crate::mcp::{Backend, SocketBackend};

/// Opens every URL in `args`; returns the exit status.
pub fn open_url(args: &[String]) -> i32 {
    let urls: Vec<&String> = args.iter().filter(|a| !a.starts_with('-')).collect();
    if urls.is_empty() {
        eprintln!("usage: {} open-url <url>…", brand::HOOK_BIN);
        return 2;
    }
    let mut backend = SocketBackend::from_args(&[]).ok();
    let mut status = 0;
    for url in urls {
        let reply = backend
            .as_mut()
            .map(|b| b.browser(BrowserAsk::Open { url: url.clone() }));
        match reply {
            Some(Ok(BrowserReply::Opened)) => {}
            Some(Ok(BrowserReply::Error(why))) => {
                eprintln!("{}: {why}", brand::HOOK_BIN);
                status = 1;
            }
            _ => {
                if !system_open(url) {
                    status = 1;
                }
            }
        }
    }
    status
}

/// The system's opener, when there is a screen to open on. `BROWSER` is cleared for it so
/// `xdg-open` cannot hand the URL back to us.
fn system_open(url: &str) -> bool {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else if std::env::var_os("DISPLAY").is_some() || std::env::var_os("WAYLAND_DISPLAY").is_some()
    {
        "xdg-open"
    } else {
        return false;
    };
    Command::new(opener)
        .arg(url)
        .env_remove("BROWSER")
        .stdin(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}
