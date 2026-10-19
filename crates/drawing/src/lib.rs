//! The drawing model shared by the daemon, the client core and the `un` CLI
//!
//! - [`InkPoint`] and the packed wire form of stroke points ([`pack`] / [`unpack`]), with
//!   [`simplify`] (Ramer–Douglas–Peucker) for committed strokes.
//! - [`Scene`]: a drawing materialised from its op log; batches apply in version order.
//! - [`to_svg`]: deterministic SVG export from vector elements.
//! - [`rasterize`] + [`encode_png`]: a small CPU rasteriser for headless PNGs, and [`braille`]
//!   for terminals without graphics.
//! - [`ExScene`]: Excalidraw scenes reconciled per element, `.excalidraw` files.
//! - [`to_ascii`]: box-glyph text rendering for terminals and agents.
//! - [`sniff`]: PNG/JPEG format and size from the header.

mod ascii;
mod excalidraw;
mod image;
mod points;
mod raster;
mod scene;
mod svg;

pub use ascii::{ASCII_CELL, to_ascii};
pub use excalidraw::{ExScene, ExcalidrawFile, parse_element, parse_file, wins};
pub use image::{encode_png, sniff};
pub use points::{InkPoint, MAX_POINTS, PointsError, QUANTUM, count, pack, simplify, unpack};
pub use raster::{RasterOptions, Rgba, braille, rasterize};
pub use scene::{Scene, VersionGap};
pub use svg::{CELL_H, CELL_W, data_uri, to_svg};
