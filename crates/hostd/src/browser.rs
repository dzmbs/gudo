//! `gudo-hook open-url <url>…`: the panes' `BROWSER`. Each URL goes to the app showing the pane
//! (a sign-in page opens in a system sign-in sheet there, anything else in its browser). With
//! no app to take it, the system's own opener runs when there is a display; else it fails, so
//! the program prints its URL instead.

use std::process::{Command, Stdio};

use daemon::{BrowserAsk, BrowserReply};

use crate::mcp::{Backend, SocketBackend};

/// `gudo-hook browser <verb> …` in a pane (its `GUDO_PANE_ID`); returns the exit status.
pub fn cli(args: &[String]) -> i32 {
    match SocketBackend::from_args(&[]) {
        Ok(mut backend) => crate::browser_tools::cli(args, &mut backend),
        Err(e) => {
            eprintln!("{}: {e}", brand::HOOK_BIN);
            2
        }
    }
}

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
    // `open`/`xdg-open` also launch apps and run files (`file:///…/x.command`), and a URL
    // here can come from anything a program read.
    if !is_web_url(url) {
        eprintln!(
            "{}: not opening {url:?}: only http and https URLs",
            brand::HOOK_BIN
        );
        return false;
    }
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

/// An `http`/`https` URL with a host and no control characters.
fn is_web_url(url: &str) -> bool {
    let lower = url.get(..8).unwrap_or(url).to_ascii_lowercase();
    let rest = if lower.starts_with("https://") {
        &url[8..]
    } else if lower.starts_with("http://") {
        &url[7..]
    } else {
        return false;
    };
    !rest.is_empty() && !rest.starts_with('/') && !url.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_system_opener_gets_web_urls_only() {
        assert!(is_web_url("https://claude.ai/oauth?x=1"));
        assert!(is_web_url("HTTP://localhost:3000/"));
        assert!(!is_web_url("file:///Users/me/Downloads/run.command"));
        assert!(!is_web_url("/Applications/Calculator.app"));
        assert!(!is_web_url(
            "x-apple.systempreferences:com.apple.preference"
        ));
        assert!(!is_web_url("http:///etc/passwd"));
        assert!(!is_web_url("https://x/\n--args"));
        assert!(!is_web_url("-a"));
    }
}
