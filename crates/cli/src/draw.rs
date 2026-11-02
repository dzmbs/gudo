//! `gudo draw`: list, show, export and send drawings and images.
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
    /// Write a PNG (the image, the drawing's preview or a daemon render), an SVG, ASCII text,
    /// or an `.excalidraw` file.
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
    /// A drawing's finished versions, newest first.
    History { id: u64 },
    /// Bring a drawing back to a version from its history (as a new version on top).
    Restore { id: u64, version: u64 },
    /// Show an artifact inline in a pane at its cursor row (as the app's "done" does).
    Place {
        id: u64,
        /// The pane (default: focused).
        #[arg(long)]
        pane: Option<u64>,
        #[arg(long)]
        version: Option<u64>,
    },
    /// Turn an image or `.excalidraw` file into an artifact placed inline in a pane.
    Import {
        file: std::path::PathBuf,
        #[arg(long)]
        pane: Option<u64>,
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
    /// Box-glyph text (shapes, arrows, text) for terminals and agents.
    Ascii,
    /// An `.excalidraw` file (scenes and images), images embedded.
    Excalidraw,
}

pub(crate) async fn run(conn: &mut Conn, action: DrawCmd) -> Result<()> {
    let session = conn.layout().session_id;
    match action {
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
                print_kitty(&png, width)?;
                return Ok(());
            }
            let pure_ink = scene.info.kind == ArtifactKind::Drawing
                && conn.client.artifact_scene(id).is_some_and(|(_, ink)| {
                    ink.elements()
                        .iter()
                        .all(|element| matches!(element.kind, ElementKind::Stroke(_)))
                });
            if pure_ink {
                let (_, ink) = conn.client.artifact_scene(id).context("scene")?;
                if version.is_some_and(|version| version != ink.version) {
                    bail!("past versions are shown with --mode kitty, or `gudo draw export`");
                }
                print!("{}", summary(&ink));
                let image = drawing::rasterize(
                    &ink,
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
                print!("{}", drawing::braille(&image, width));
            } else {
                // Shapes, arrows and text read best as box glyphs (agents read this too).
                let (_, text) = conn
                    .client
                    .artifact_export(id, version, ExportFormat::Ascii)
                    .await?;
                print!("{}", String::from_utf8_lossy(&text));
            }
        }
        DrawCmd::History { id } => {
            let history = conn.client.artifact_history(ArtifactId(id)).await?;
            if history.is_empty() {
                println!("no finished versions yet");
            }
            for entry in history {
                let restored = entry
                    .restored_from
                    .map(|from| format!(", restored v{from}"))
                    .unwrap_or_default();
                let render = entry.image.map_or("no render".to_owned(), |image| {
                    format!("{}×{} render", image.width, image.height)
                });
                println!(
                    "v{:<4} {:>3} elements  {render}  at {} ms{restored}",
                    entry.version, entry.elements, entry.at.0
                );
            }
        }
        DrawCmd::Restore { id, version } => {
            let (info, entry) = conn
                .client
                .artifact_restore(ArtifactId(id), version)
                .await?;
            println!(
                "restored artifact {} v{version} as v{} ({} elements)",
                info.artifact_id, entry.version, info.elements
            );
        }
        DrawCmd::Place { id, pane, version } => {
            let pane = match pane {
                Some(pane) => PaneId(pane),
                None => conn.tab()?.focused,
            };
            let placed = conn
                .client
                .place(client_core::proto::PlaceRequest {
                    pane_id: pane,
                    artifact_id: ArtifactId(id),
                    version,
                    anchor: None,
                    col: 0,
                    cols: 0,
                    rows: 0,
                    png: None,
                    replace: None,
                })
                .await?;
            println!(
                "placed artifact {} v{} in pane {pane} at the cursor row: {}×{} cells (placement {})",
                placed.artifact_id, placed.version, placed.cols, placed.rows, placed.placement_id
            );
        }
        DrawCmd::Import { file, pane } => {
            let pane = match pane {
                Some(pane) => PaneId(pane),
                None => conn.tab()?.focused,
            };
            let bytes =
                std::fs::read(&file).with_context(|| format!("reading {}", file.display()))?;
            let name = file
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            let placed = conn.client.import_to_pane(pane, name, bytes).await?;
            println!(
                "imported as artifact {} and placed in pane {pane}: {}×{} cells",
                placed.artifact_id, placed.cols, placed.rows
            );
        }
        DrawCmd::Export {
            id,
            format,
            version,
            output,
        } => {
            let format = match format {
                Format::Png => Some(ExportFormat::Png),
                Format::Svg => Some(ExportFormat::Svg),
                Format::Ascii => Some(ExportFormat::Ascii),
                Format::Excalidraw => None,
            };
            let (exported_version, data) = match format {
                Some(format) => {
                    conn.client
                        .artifact_export(ArtifactId(id), version, format)
                        .await?
                }
                None => {
                    if version.is_some() {
                        bail!("--version is for PNG, SVG and ASCII (restore it first)");
                    }
                    let data = conn.client.excalidraw_file(ArtifactId(id)).await?;
                    let current = conn.client.artifact_get(ArtifactId(id), u64::MAX).await?;
                    (current.info.version, data)
                }
            };
            match output {
                Some(path) => {
                    std::fs::write(&path, &data)?;
                    eprintln!(
                        "wrote {} (version {exported_version}, {} bytes)",
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
                Some(pane) => PaneId(pane),
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
        ArtifactKind::Excalidraw => "diagram",
    };
    let place = match (&info.anchor, info.canvas_panes.as_slice()) {
        (Some(anchor), _) => match anchor.state {
            AnchorState::Live => format!(
                "ink on pane {} ({} rows up{})",
                anchor.pane_id,
                anchor.from_bottom,
                anchor
                    .command_id
                    .map(|command| format!(", command {command}"))
                    .unwrap_or_default()
            ),
            AnchorState::Detached(reason) => {
                format!("loose (was on pane {}: {reason:?})", anchor.pane_id)
            }
        },
        (None, [pane, ..]) => format!("canvas pane {pane}"),
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
    for element in scene.elements() {
        match &element.kind {
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
    for label in labels {
        out.push_str(&format!("  text: {label}\n"));
    }
    out
}

/// kitty graphics: from the environment, else by asking the terminal (`a=q`, then DA1 so a
/// terminal without graphics still answers something).
fn kitty_supported() -> bool {
    let env = |name: &str| std::env::var(name).unwrap_or_default();
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
        while let Ok(read) = stdin.read(&mut buf) {
            if read == 0 {
                break;
            }
            seen.extend_from_slice(&buf[..read]);
            // DA1 answer ends the exchange.
            if seen.windows(2).any(|pair| pair[0] == b'?') && seen.ends_with(b"c") {
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

/// Prints a PNG with the kitty graphics protocol (`f=100`, chunked base64) at most `width`
/// columns wide, then moves below it. The image is placed with `C=1` (cursor stays) and
/// explicit `c`/`r`, and the rows are reserved with newlines, so the layout is the same in
/// kitty, Ghostty, WezTerm and our own panes (whose daemon keeps the image as an inline
/// placement).
fn print_kitty(png: &[u8], width: usize) -> Result<()> {
    let term_cols = rustix::termios::tcgetwinsize(rustix::stdio::stdout())
        .map(|size| usize::from(size.ws_col))
        .unwrap_or(80)
        .max(1);
    let (image_w, image_h) =
        drawing::sniff(png).map_or((1, 1), |(_, width, height)| (width.max(1), height));
    // Images are 2× renders; a cell is about 9×18 points.
    let cols = (image_w as usize / 18).clamp(1, width.min(term_cols));
    let rows = ((cols as f64 * 9.0 * f64::from(image_h) / f64::from(image_w) / 18.0).round()
        as usize)
        .max(1);
    let encoded = data_encoding::BASE64.encode(png);
    let mut out = std::io::stdout().lock();
    let chunks: Vec<&[u8]> = encoded.as_bytes().chunks(4096).collect();
    for (i, chunk) in chunks.iter().enumerate() {
        let more = u8::from(i + 1 < chunks.len());
        if i == 0 {
            write!(out, "\x1b_Ga=T,f=100,C=1,q=2,c={cols},r={rows},m={more};")?;
        } else {
            write!(out, "\x1b_Gm={more};")?;
        }
        out.write_all(chunk)?;
        out.write_all(b"\x1b\\")?;
    }
    out.write_all("\n".repeat(rows).as_bytes())?;
    out.flush()?;
    Ok(())
}
