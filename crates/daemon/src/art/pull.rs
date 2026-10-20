//! The pull channel (docs/DAEMON.md §7.12): agents read their session's drawings themselves.
//!
//! `un-hook mcp` (an MCP server the agent runs) sends one [`PullCall`] line on the hook socket
//! and reads one [`PullReply`] line, like the askpass helper. The pane named in the call picks
//! the session; only that session's artifacts are visible.

use std::sync::Arc;

use proto::{ArtifactInfo, ArtifactKind, ExportFormat, PaneId};
use serde::{Deserialize, Serialize};

use crate::core::Core;

/// The pull protocol version in [`PullCall::v`].
pub const PULL_VERSION: u32 = 1;

/// Largest export returned, in bytes before base64.
pub const PULL_MAX: usize = 8 << 20;

/// An export format the pull channel offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PullFormat {
    /// The name on the wire and in the MCP tool's schema.
    pub name: &'static str,
    /// What the artifact store exports.
    pub export: ExportFormat,
    /// The MIME type of the result (a PNG export of a JPEG image is sniffed as JPEG).
    pub mime: &'static str,
    /// Binary results travel base64-encoded; text ones as UTF-8.
    pub binary: bool,
}

/// Every format the pull channel offers; the first is the default. Adding an
/// [`ExportFormat`] here is all it takes to offer it to agents.
pub const PULL_FORMATS: &[PullFormat] = &[
    PullFormat::new("png", ExportFormat::Png, "image/png", true),
    PullFormat::new("svg", ExportFormat::Svg, "image/svg+xml", false),
    PullFormat::new("ascii", ExportFormat::Ascii, "text/plain", false),
];

impl PullFormat {
    const fn new(
        name: &'static str,
        export: ExportFormat,
        mime: &'static str,
        binary: bool,
    ) -> Self {
        Self {
            name,
            export,
            mime,
            binary,
        }
    }

    /// The format called `name`.
    pub fn by_name(name: &str) -> Option<&'static Self> {
        PULL_FORMATS.iter().find(|f| f.name == name)
    }
}

/// What the MCP server sends on the hook socket: one JSON line.
///
/// ```json
/// {"v":1,"token":"…","pane":"12","pull":{"op":"get","id":3,"format":"png"}}
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullCall {
    /// [`PULL_VERSION`].
    pub v: u32,
    /// The hook token (`<state>/hook.token`).
    pub token: String,
    /// The pane whose session is read.
    pub pane: String,
    /// What to do.
    pub pull: PullOp,
}

/// A pull operation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum PullOp {
    /// The session's artifacts, most recently updated first.
    List,
    /// One artifact, exported.
    Get {
        /// The artifact; the session's most recently updated drawing when absent.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<u64>,
        /// A [`PullFormat::name`]; `png` when absent.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        format: Option<String>,
        /// The version; the current one when absent.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        version: Option<u64>,
    },
}

/// The daemon's answer to a [`PullCall`]: one JSON line, `{"list":…}`, `{"export":…}` or
/// `{"error":"…"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PullReply {
    /// The answer to [`PullOp::List`].
    List {
        /// The pane's session.
        session: u64,
        /// Its artifacts, most recently updated first.
        artifacts: Vec<PullSummary>,
    },
    /// The answer to [`PullOp::Get`].
    Export(PullExport),
    /// Why the call failed; never carries data.
    Error(String),
}

/// One artifact in a [`PullReply::List`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PullSummary {
    /// The artifact id.
    pub id: u64,
    /// `drawing`, `excalidraw` or `image`.
    pub kind: String,
    /// Its title (may be empty).
    pub title: String,
    /// Its version.
    pub version: u64,
    /// Last change, Unix milliseconds.
    pub updated_at: u64,
    /// Elements now (0 for images).
    pub elements: u32,
    /// Panes it is placed in, inline in the output.
    pub placed_in: Vec<u64>,
    /// Canvas panes showing it.
    pub canvas_in: Vec<u64>,
    /// For ink drawn over a terminal: that pane.
    pub ink_over: Option<u64>,
    /// Pixel width of the image or of the last rendered preview, if known.
    pub width: Option<u32>,
    /// Pixel height, likewise.
    pub height: Option<u32>,
}

/// One exported artifact in a [`PullReply::Export`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PullExport {
    /// The artifact id.
    pub id: u64,
    /// Its title.
    pub title: String,
    /// The version exported.
    pub version: u64,
    /// The [`PullFormat::name`].
    pub format: String,
    /// The MIME type of `data`.
    pub mime: String,
    /// Base64 for binary formats, the text itself otherwise.
    pub data: String,
    /// Whether `data` is base64.
    pub base64: bool,
}

/// Answers one pull call.
pub(crate) async fn serve(core: &Arc<Core>, call: PullCall) -> PullReply {
    if call.token != core.hooks.token() {
        tracing::warn!("pull call with a bad token");
        return PullReply::Error("bad token".into());
    }
    if call.v != PULL_VERSION {
        return PullReply::Error(format!("unsupported pull version {}", call.v));
    }
    let Some(session) = call
        .pane
        .parse()
        .ok()
        .and_then(|p| core.session_of_pane(PaneId(p)))
    else {
        return PullReply::Error(format!("pane {} is in no session", call.pane));
    };
    let core = Arc::clone(core);
    // Exports may rasterise; keep that off the async workers.
    tokio::task::spawn_blocking(move || {
        let art = &core.art;
        let mut items = art.list(session);
        items.sort_by_key(|i| std::cmp::Reverse((i.updated_at.0, i.artifact_id.0)));
        match call.pull {
            PullOp::List => PullReply::List {
                session: session.0,
                artifacts: items.iter().map(|i| summary(art, i)).collect(),
            },
            PullOp::Get {
                id,
                format,
                version,
            } => get(art, &items, id, format.as_deref(), version)
                .map_or_else(PullReply::Error, PullReply::Export),
        }
    })
    .await
    .unwrap_or_else(|e| PullReply::Error(format!("export failed: {e}")))
}

fn summary(art: &super::Art, info: &ArtifactInfo) -> PullSummary {
    let size = info.image.or(info.preview.map(|p| p.image));
    PullSummary {
        id: info.artifact_id.0,
        kind: kind_name(info.kind).into(),
        title: info.title.clone(),
        version: info.version,
        updated_at: info.updated_at.0,
        elements: info.elements,
        placed_in: art
            .placement_panes(info.artifact_id)
            .into_iter()
            .map(|p| p.0)
            .collect(),
        canvas_in: info.canvas_panes.iter().map(|p| p.0).collect(),
        ink_over: info.anchor.as_ref().map(|a| a.pane_id.0),
        width: size.map(|s| s.width),
        height: size.map(|s| s.height),
    }
}

fn kind_name(kind: ArtifactKind) -> &'static str {
    match kind {
        ArtifactKind::Drawing => "drawing",
        ArtifactKind::Excalidraw => "excalidraw",
        ArtifactKind::Image => "image",
    }
}

/// Exports artifact `id` of the session whose artifacts are `items` (newest first).
fn get(
    art: &super::Art,
    items: &[ArtifactInfo],
    id: Option<u64>,
    format: Option<&str>,
    version: Option<u64>,
) -> Result<PullExport, String> {
    let format = match format {
        None => &PULL_FORMATS[0],
        Some(name) => PullFormat::by_name(name).ok_or_else(|| {
            let known: Vec<_> = PULL_FORMATS.iter().map(|f| f.name).collect();
            format!("unknown format {name:?} (one of {})", known.join(", "))
        })?,
    };
    let info = match id {
        // Another session's id reads as unknown, like an id that never existed.
        Some(id) => items
            .iter()
            .find(|i| i.artifact_id.0 == id)
            .ok_or_else(|| format!("no artifact {id} in this session"))?,
        None => items
            .iter()
            .find(|i| i.kind != ArtifactKind::Image)
            .ok_or("no drawings in this session")?,
    };
    let exported =
        super::export(art, info.artifact_id, version, format.export).map_err(|e| e.to_string())?;
    let data = match exported.blob {
        Some(hash) => art.read_blob(&hash).map_err(|e| e.to_string())?.1,
        None => exported.data,
    };
    if data.len() > PULL_MAX {
        return Err(format!(
            "the {} export is {} bytes, over the {} MiB limit; try svg or ascii",
            format.name,
            data.len(),
            PULL_MAX >> 20
        ));
    }
    let (mime, data) = if format.binary {
        (
            sniff(&data).unwrap_or(format.mime),
            data_encoding::BASE64.encode(&data),
        )
    } else {
        let text = String::from_utf8(data).map_err(|_| "the export is not UTF-8 text")?;
        (format.mime, text)
    };
    Ok(PullExport {
        id: info.artifact_id.0,
        title: info.title.clone(),
        version: exported.version,
        format: format.name.into(),
        mime: mime.into(),
        data,
        base64: format.binary,
    })
}

/// The image type of `bytes`, from its signature.
fn sniff(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG") {
        Some("image/png")
    } else if bytes.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("image/jpeg")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calls_and_replies_have_the_documented_shape() {
        let call: PullCall =
            serde_json::from_str(r#"{"v":1,"token":"t","pane":"4","pull":{"op":"list"}}"#).unwrap();
        assert_eq!(call.pull, PullOp::List);
        let call: PullCall = serde_json::from_str(
            r#"{"v":1,"token":"t","pane":"4","pull":{"op":"get","id":3,"format":"svg"}}"#,
        )
        .unwrap();
        assert_eq!(
            call.pull,
            PullOp::Get {
                id: Some(3),
                format: Some("svg".into()),
                version: None
            }
        );
        // Never mistaken for the other calls on the socket.
        assert!(
            serde_json::from_str::<crate::askpass::AskpassCall>(
                r#"{"v":1,"token":"t","pane":"4","pull":{"op":"list"}}"#
            )
            .is_err()
        );
        assert_eq!(
            serde_json::to_string(&PullReply::Error("bad token".into())).unwrap(),
            r#"{"error":"bad token"}"#
        );
    }

    #[test]
    fn formats_are_looked_up_by_name() {
        assert_eq!(PULL_FORMATS[0].name, "png");
        assert_eq!(
            PullFormat::by_name("ascii").unwrap().export,
            ExportFormat::Ascii
        );
        assert!(PullFormat::by_name("gif").is_none());
        assert_eq!(sniff(b"\x89PNG\r\n"), Some("image/png"));
        assert_eq!(sniff(b"<svg"), None);
    }
}
