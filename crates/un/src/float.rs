//! Floating windows: open a command over the tab in a window of its own, move, minimize, pin
//! and dock windows, and list them.

use anyhow::{Context, Result, bail};
use clap::{Subcommand, ValueEnum};
use client_core::ClientEvent;
use client_core::proto::{
    CloseWhen, Direction, DockTarget, FloatFrame, LayoutOp, OpOutcome, PaneId, PaneLaunch,
};

use crate::Conn;

#[derive(Subcommand)]
pub(crate) enum FloatCmd {
    /// Open a shell in a floating window over the focused pane's tab and run `COMMAND` in it
    /// (just the shell without one). Prints the new pane's id. The window does not take the
    /// focus unless `--focus`.
    Run {
        /// Close the window 2.5 s after the command finishes.
        #[arg(long)]
        close_when_done: bool,
        /// `x,y,w,h` in fractions of the tab (default: a free spot).
        #[arg(long, value_parser = parse_frame)]
        frame: Option<FloatFrame>,
        /// Move the focus into it.
        #[arg(long)]
        focus: bool,
        /// Over this pane's tab (default: the focused one).
        #[arg(long)]
        over: Option<String>,
        /// Working directory (default: the pane's).
        #[arg(long)]
        cwd: Option<String>,
        /// The command line; words are quoted for the shell, a single argument is run as is.
        #[arg(last = true)]
        command: Vec<String>,
    },
    /// Float a pane in a window of its own, or move a one-pane window.
    Pane {
        pane: String,
        #[arg(long, value_parser = parse_frame)]
        frame: Option<FloatFrame>,
    },
    /// Move the window holding a pane.
    Move {
        pane: String,
        #[arg(value_parser = parse_frame)]
        frame: FloatFrame,
    },
    /// Dock the window holding a pane: where it is, or beside another pane.
    Dock {
        pane: String,
        #[arg(long)]
        beside: Option<String>,
        #[arg(long, value_enum, default_value_t = Side::Right)]
        side: Side,
    },
    /// Send the window holding a pane to the tab's tray.
    Min { pane: String },
    /// Bring the window holding a pane back from the tray, in front.
    Restore { pane: String },
    /// Show the window holding a pane over every tab (`--off` to stop).
    Pin {
        pane: String,
        #[arg(long)]
        off: bool,
    },
    /// The attached session's floating windows, back to front.
    List,
}

#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum Side {
    Left,
    Right,
    Up,
    Down,
}

impl From<Side> for Direction {
    fn from(s: Side) -> Self {
        match s {
            Side::Left => Self::Left,
            Side::Right => Self::Right,
            Side::Up => Self::Up,
            Side::Down => Self::Down,
        }
    }
}

/// `x,y,w,h` as fractions of the tab.
fn parse_frame(s: &str) -> Result<FloatFrame, String> {
    let v: Vec<f32> = s
        .split(',')
        .map(|p| p.trim().parse::<f32>())
        .collect::<Result<_, _>>()
        .map_err(|e| format!("{s:?}: {e}"))?;
    let [x, y, w, h] = v[..] else {
        return Err(format!("{s:?}: want x,y,w,h"));
    };
    FloatFrame { x, y, w, h }
        .clamped()
        .ok_or_else(|| format!("{s:?}: not numbers"))
}

/// `p12` or `12`.
fn pane(s: &str) -> Result<PaneId> {
    s.trim_start_matches('p')
        .parse()
        .map(PaneId)
        .with_context(|| format!("{s:?} is not a pane id"))
}

/// One shell line from words: a single word is a line already; more are quoted one by one.
fn shell_line(words: &[String]) -> String {
    if let [line] = words {
        return line.clone();
    }
    words
        .iter()
        .map(|w| {
            if !w.is_empty()
                && w.chars()
                    .all(|c| c.is_ascii_alphanumeric() || "-_./=:,@+%".contains(c))
            {
                w.clone()
            } else {
                format!("'{}'", w.replace('\'', r"'\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub(crate) async fn run(conn: &mut Conn, cmd: FloatCmd) -> Result<()> {
    let set = |pane_id, frame, minimized, pinned| LayoutOp::SetFloat {
        pane_id,
        frame,
        minimized,
        pinned,
    };
    match cmd {
        FloatCmd::Run {
            close_when_done,
            frame,
            focus,
            over,
            cwd,
            command,
        } => {
            let over = match over {
                Some(p) => pane(&p)?,
                None => conn.tab()?.focused,
            };
            // A shell that runs the command, so its output stays to read and the command's
            // end (shell integration) is what closes the window.
            let outcome = conn
                .op(LayoutOp::NewFloat {
                    pane_id: over,
                    launch: PaneLaunch::Shell { cwd },
                    frame,
                    focus,
                    close: if close_when_done {
                        CloseWhen::Done
                    } else {
                        CloseWhen::Never
                    },
                })
                .await?;
            let OpOutcome::PaneCreated { pane_id } = outcome else {
                bail!("unexpected answer: {outcome:?}");
            };
            if !command.is_empty() {
                conn.client.subscribe(pane_id);
                conn.client
                    .send_input(pane_id, format!("{}\r", shell_line(&command)).into_bytes());
                // Acknowledged once the shell echoes it; give it a moment rather than wait.
                let _ = tokio::time::timeout(
                    std::time::Duration::from_millis(1500),
                    conn.answer(|e| match e {
                        ClientEvent::InputAck { pane_id: p, .. } if p == pane_id => Some(()),
                        _ => None,
                    }),
                )
                .await;
            }
            println!("p{}", pane_id.0);
        }
        FloatCmd::Pane { pane: p, frame } => {
            conn.op(LayoutOp::FloatPane {
                pane_id: pane(&p)?,
                frame,
            })
            .await?;
        }
        FloatCmd::Move { pane: p, frame } => {
            conn.op(set(pane(&p)?, Some(frame), None, None)).await?;
        }
        FloatCmd::Dock {
            pane: p,
            beside,
            side,
        } => {
            let beside = beside
                .map(|b| {
                    pane(&b).map(|pane_id| DockTarget {
                        pane_id,
                        side: side.into(),
                    })
                })
                .transpose()?;
            conn.op(LayoutOp::DockPane {
                pane_id: pane(&p)?,
                beside,
            })
            .await?;
        }
        FloatCmd::Min { pane: p } => {
            conn.op(set(pane(&p)?, None, Some(true), None)).await?;
        }
        FloatCmd::Restore { pane: p } => {
            conn.op(set(pane(&p)?, None, Some(false), None)).await?;
        }
        FloatCmd::Pin { pane: p, off } => {
            conn.op(set(pane(&p)?, None, None, Some(!off))).await?;
        }
        FloatCmd::List => {
            conn.wait("floating windows (the daemon may predate them)", |c| {
                c.floats.is_some()
            })
            .await?;
            let floats = conn.floats.as_ref().expect("waited for");
            if floats.floats.is_empty() {
                println!("no floating windows");
            }
            for w in &floats.floats {
                let panes: Vec<String> = w.panes.iter().map(|p| format!("p{}", p.0)).collect();
                let f = w.frame;
                let mut flags = Vec::new();
                if w.minimized {
                    flags.push("minimized");
                }
                if w.pinned {
                    flags.push("pinned");
                }
                if w.close == CloseWhen::Done {
                    flags.push("closes when done");
                }
                println!(
                    "w{:<4} {:<16} {:.2},{:.2} {:.2}×{:.2}  {}",
                    w.id.0,
                    panes.join(","),
                    f.x,
                    f.y,
                    f.w,
                    f.h,
                    flags.join(", ")
                );
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_parse_and_stay_inside_the_tab() {
        assert_eq!(
            parse_frame("0.9, 0, 0.5,0.5").unwrap(),
            FloatFrame {
                x: 0.5,
                y: 0.0,
                w: 0.5,
                h: 0.5
            }
        );
        assert!(parse_frame("0,0,1").is_err());
        assert!(parse_frame("a,0,1,1").is_err());
    }

    #[test]
    fn words_are_quoted_for_the_shell() {
        assert_eq!(shell_line(&["tail -f log".into()]), "tail -f log");
        assert_eq!(
            shell_line(&["echo".into(), "it's done".into(), "a=b".into()]),
            r"echo 'it'\''s done' a=b"
        );
    }
}
