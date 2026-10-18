//!
//! `show` prints the PNG with the kitty graphics protocol when the terminal supports it
//! (kitty, Ghostty, WezTerm: detected from the environment, else by an `a=q` query), and a
//! braille rendering plus a summary otherwise.

use std::io::{Read, Write};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Subcommand, ValueEnum};
use client_core::drawing;
use client_core::proto::{
    AnchorState, ArtifactId, ArtifactInfo, ArtifactKind, CoordSpace, ElementKind, ExportFormat,
    PaneId,
};

use crate::Conn;

#[derive(Subcommand)]
pub(crate) enum DrawCmd {
    /// The attached session's drawings and images.
    #[command(alias = "ls")]
    List,
    /// Show a drawing or image here (kitty graphics, else braille).
    Show {
        id: u64,
        /// A past version (drawings).
        #[arg(long)]
        version: Option<u64>,
        /// Force an output form.
        #[arg(long, value_enum)]
        mode: Option<ShowMode>,
        /// Width in columns for the braille rendering.
        #[arg(long, default_value_t = 80)]
        width: usize,
    },
    /// Write a PNG (the image, the drawing's preview or a daemon render) or an SVG.
    Export {
        id: u64,
        #[arg(long, value_enum, default_value_t = Format::Png)]
        format: Format,
        #[arg(long)]
        version: Option<u64>,
        /// Output file (default: stdout).
        #[arg(short, long)]
        output: Option<std::path::PathBuf>,
    },
    /// Hand a drawing (or a local PNG/JPEG file) to the agent in a pane: the daemon writes
    /// it on the host and pastes its path, which Claude Code and Codex attach as an image.
    Send {
        /// The drawing or image to send.
        #[arg(required_unless_present = "file")]
        id: Option<u64>,
        /// A local image file instead.
        #[arg(long, conflicts_with = "id")]
        file: Option<std::path::PathBuf>,
        /// The agent pane (default: focused).
        #[arg(long)]
        pane: Option<u64>,
        #[arg(long)]
        version: Option<u64>,
    },
}

#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum ShowMode {
    Kitty,
    Ascii,
}

#[derive(Clone, Copy, ValueEnum)]
pub(crate) enum Format {
    Png,
    Svg,
}

pub(crate) async fn run(conn: &mut Conn, cmd: DrawCmd) -> Result<()> {
    let session = conn.layout().session_id;
    match cmd {
        DrawCmd::List => {
            let list = conn.client.artifacts(session).await?;
            if list.is_empty() {
                println!("no drawings or images in this session");
            }
            for info in list {
                println!("{}", line(&info));
            }
        }
        DrawCmd::Show {
            id,
            version,
            mode,
            width,
        } => {
            let id = ArtifactId(id);
            let scene = conn.client.artifact_get(id, 0).await?;
            println!("{}", line(&scene.info));
            let kitty = match mode {
                Some(ShowMode::Kitty) => true,
                Some(ShowMode::Ascii) => false,
                None => kitty_supported(),
            };
            if kitty {
                let (_, png) = conn
                    .client
                    .artifact_export(id, version, ExportFormat::Png)
                    .await?;
                print_kitty(&png)?;
                return Ok(());
            }
            match scene.info.kind {
                ArtifactKind::Image => {
                    let img = scene.info.image.context("image without blob")?;
                    println!(
                        "image {}×{}, {} bytes ({})",
                        img.width,
                        img.height,
                        img.size,
                        img.media.mime()
                    );
                }
                ArtifactKind::Drawing => {
                    let (_, s) = conn
                        .client
                        .artifact_scene(id)
                        .unwrap_or((scene.info.clone(), drawing::Scene::new()));
                    if version.is_some_and(|v| v != s.version) {
                        bail!("past versions are shown with --mode kitty, or `un draw export`");
                    }
                    print!("{}", summary(&s));
                    let img = drawing::rasterize(
                        &s,
                        scene.info.space,
                        drawing::RasterOptions {
                            scale: if scene.info.space == CoordSpace::Cells {
                                1.0
                            } else {
                                2.0
                            },
                            ..drawing::RasterOptions::default()
                        },
                    );
                    print!("{}", drawing::braille(&img, width));
                }
            }
        }
        DrawCmd::Export {
            id,
            format,
            version,
            output,
        } => {
            let format = match format {
                Format::Png => ExportFormat::Png,
                Format::Svg => ExportFormat::Svg,
            };
            let (v, data) = conn
                .client
                .artifact_export(ArtifactId(id), version, format)
                .await?;
            match output {
                Some(path) => {
                    std::fs::write(&path, &data)?;
                    eprintln!(
                        "wrote {} (version {v}, {} bytes)",
                        path.display(),
                        data.len()
                    );
                }
                None => std::io::stdout().write_all(&data)?,
            }
        }
        DrawCmd::Send {
            id,
            file,
            pane,
            version,
        } => {
            let pane = match pane {
                Some(p) => PaneId(p),
                None => conn.tab()?.focused,
            };
            let sent = match file {
                Some(path) => {
                    let bytes = std::fs::read(&path)
                        .with_context(|| format!("reading {}", path.display()))?;
                    if drawing::sniff(&bytes).is_none() {
                        bail!("{} is not a PNG or JPEG image", path.display());
                    }
                    conn.client
                        .send_to_agent(pane, None, None, Some(bytes))
                        .await?
                }
                None => {
                    let id = ArtifactId(id.context("an artifact id or --file")?);
                    conn.client
                        .send_to_agent(pane, Some(id), version, None)
                        .await?
                }
            };
            println!(
                "sent artifact {} v{} to pane {pane}: {}{}",
                sent.artifact_id,
                sent.version,
                sent.path,
                if sent.bracketed {
                    ""
                } else {
                    " (the pane has no bracketed paste: is an agent running?)"
                }
            );
        }
    }
    Ok(())
}

fn line(info: &ArtifactInfo) -> String {
    let kind = match info.kind {
        ArtifactKind::Drawing => "drawing",
        ArtifactKind::Image => "image",
    };
    let place = match (&info.anchor, info.canvas_panes.as_slice()) {
        (Some(a), _) => match a.state {
            AnchorState::Live => format!(
                "ink on pane {} ({} rows up{})",
                a.pane_id,
                a.from_bottom,
                a.command_id
                    .map(|c| format!(", command {c}"))
                    .unwrap_or_default()
            ),
            AnchorState::Detached(r) => format!("loose (was on pane {}: {r:?})", a.pane_id),
        },
        (None, [p, ..]) => format!("canvas pane {p}"),
        (None, []) => "loose".into(),
    };
    format!(
        "{:>4}  {kind:<7} v{:<4} {:>5} elements  {place}  {}",
        info.artifact_id,
        info.version,
        info.elements,
        if info.title.is_empty() {
            "(untitled)"
        } else {
            &info.title
        }
    )
}

fn summary(scene: &drawing::Scene) -> String {
    let (mut strokes, mut shapes, mut texts, mut images) = (0, 0, 0, 0);
    let mut labels = Vec::new();
    for e in scene.elements() {
        match &e.kind {
            ElementKind::Stroke(_) => strokes += 1,
            ElementKind::Shape { .. } => shapes += 1,
            ElementKind::Text { text, .. } => {
                texts += 1;
                labels.push(text.replace('\n', " "));
            }
            ElementKind::Image { .. } => images += 1,
        }
    }
    let mut out = format!("{strokes} strokes, {shapes} shapes, {texts} texts, {images} images\n");
    for l in labels {
        out.push_str(&format!("  text: {l}\n"));
    }
    out
}

/// kitty graphics: from the environment, else by asking the terminal (`a=q`, then DA1 so a
/// terminal without graphics still answers something).
fn kitty_supported() -> bool {
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    if !env("KITTY_WINDOW_ID").is_empty()
        || env("TERM").contains("kitty")
        || env("TERM").contains("ghostty")
        || ["ghostty", "WezTerm"].contains(&env("TERM_PROGRAM").as_str())
    {
        return true;
    }
    if !rustix::termios::isatty(rustix::stdio::stdin())
        || !rustix::termios::isatty(rustix::stdio::stdout())
    {
        return false;
    }
    let Ok(_raw) = crate::RawMode::enter() else {
        return false;
    };
    let mut out = std::io::stdout();
    let _ = out.write_all(b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c");
    let _ = out.flush();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = [0u8; 256];
        let mut seen = Vec::new();
        let mut stdin = std::io::stdin();
        while let Ok(n) = stdin.read(&mut buf) {
            if n == 0 {
                break;
            }
            seen.extend_from_slice(&buf[..n]);
            // DA1 answer ends the exchange.
            if seen.windows(2).any(|w| w[0] == b'?') && seen.ends_with(b"c") {
                break;
            }
        }
        let _ = tx.send(seen);
    });
    let reply = rx
        .recv_timeout(Duration::from_millis(300))
        .unwrap_or_default();
    let reply = String::from_utf8_lossy(&reply);
    reply.contains("_Gi=31;OK")
}

/// Prints a PNG with the kitty graphics protocol (`f=100`, chunked base64).
fn print_kitty(png: &[u8]) -> Result<()> {
    let b64 = data_encoding::BASE64.encode(png);
    let mut out = std::io::stdout().lock();
    let chunks: Vec<&[u8]> = b64.as_bytes().chunks(4096).collect();
    for (i, chunk) in chunks.iter().enumerate() {
        let more = u8::from(i + 1 < chunks.len());
        if i == 0 {
            write!(out, "\x1b_Ga=T,f=100,m={more};")?;
        } else {
            write!(out, "\x1b_Gm={more};")?;
        }
        out.write_all(chunk)?;
        out.write_all(b"\x1b\\")?;
    }
    out.write_all(b"\n")?;
    out.flush()?;
    Ok(())
}
