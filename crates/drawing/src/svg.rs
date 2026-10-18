//!
//! Output is deterministic (same scene, same bytes), so it can be golden-tested:
//!
//! - strokes become one `<path>` each, smoothed with quadratic segments through the midpoints
//!   of consecutive points, `stroke-width` = width × mean pressure for pens (SVG has no
//!   variable-width stroke; a per-point outline would be exact but large);
//! - highlighters get `stroke-opacity` 0.35 and square caps; markers ignore pressure;
//! - shapes map to `<rect>`, `<ellipse>`, `<line>` (arrows add a filled head `<path>`);
//! - text becomes `<text>` with one `<tspan>` per line, XML-escaped;
//! - images become `<image>` with the href the caller supplies (a data URI, a file name), or a
//!   dashed placeholder rectangle.
//!
//! [`CoordSpace::Cells`] drawings are scaled to [`CELL_W`] × [`CELL_H`] per cell.

use std::fmt::Write as _;

use proto::{CoordSpace, ElementKind, ImageRef, ShapeKind, Tool};

use crate::points::unpack;
use crate::scene::Scene;

/// Width of one terminal cell in SVG units for cell-space drawings.
pub const CELL_W: f32 = 9.0;
/// Height of one terminal cell.
pub const CELL_H: f32 = 18.0;
const PAD: f32 = 8.0;

/// Formats a number with at most two decimals, trailing zeros trimmed.
fn num(v: f32) -> String {
    let v = if v.is_finite() { v } else { 0.0 };
    let s = format!("{:.2}", (v * 100.0).round() / 100.0);
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s == "-0" { "0".into() } else { s.into() }
}

fn color(rgba: u32) -> (String, f32) {
    (format!("#{:06x}", rgba >> 8), (rgba & 0xff) as f32 / 255.0)
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c if (c as u32) < 0x20 && c != '\t' => {}
            c => out.push(c),
        }
    }
    out
}

/// Writes `scene` as a standalone SVG document. `image_href` turns an image element's blob
/// into an `href` (or `None` for a placeholder).
pub fn to_svg(
    scene: &Scene,
    space: CoordSpace,
    title: &str,
    image_href: &dyn Fn(&ImageRef) -> Option<String>,
) -> String {
    let (sx, sy) = match space {
        CoordSpace::Canvas => (1.0, 1.0),
        CoordSpace::Cells => (CELL_W, CELL_H),
    };
    let (lo, hi) = scene
        .bounds()
        .map(|(lo, hi)| ((lo.x * sx, lo.y * sy), (hi.x * sx, hi.y * sy)))
        .unwrap_or(((0.0, 0.0), (0.0, 0.0)));
    let (x0, y0) = (lo.0 - PAD, lo.1 - PAD);
    let (w, h) = (hi.0 - lo.0 + 2.0 * PAD, hi.1 - lo.1 + 2.0 * PAD);
    let mut out = String::new();
    let _ = writeln!(
        out,
        r#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="{} {} {} {}" width="{}" height="{}">"#,
        num(x0),
        num(y0),
        num(w),
        num(h),
        num(w),
        num(h)
    );
    if !title.is_empty() {
        let _ = writeln!(out, "<title>{}</title>", escape(title));
    }
    for e in scene.draw_order() {
        let (stroke, opacity) = color(e.style.color);
        // Widths are in x units (columns for cell-space ink).
        let width = e.style.width.max(0.0) * sx;
        let opacity_attr = |o: f32| {
            if o < 1.0 {
                format!(r#" stroke-opacity="{}""#, num(o))
            } else {
                String::new()
            }
        };
        match &e.kind {
            ElementKind::Stroke(s) => {
                let pts = unpack(&s.points).unwrap_or_default();
                if pts.is_empty() {
                    continue;
                }
                let mean_p = pts.iter().map(|p| p.pressure).sum::<f32>() / pts.len() as f32;
                let (w, o, cap) = match s.tool {
                    Tool::Pen => (width * mean_p.max(0.1), opacity, "round"),
                    Tool::Marker => (width, opacity, "round"),
                    Tool::Highlighter => (width, opacity * 0.35, "square"),
                };
                let p = |i: usize| (pts[i].x * sx, pts[i].y * sy);
                let mut d = format!("M{} {}", num(p(0).0), num(p(0).1));
                if pts.len() == 1 {
                    let _ = write!(d, "L{} {}", num(p(0).0), num(p(0).1));
                } else {
                    for i in 1..pts.len() - 1 {
                        let (c, n) = (p(i), p(i + 1));
                        let _ = write!(
                            d,
                            "Q{} {} {} {}",
                            num(c.0),
                            num(c.1),
                            num((c.0 + n.0) / 2.0),
                            num((c.1 + n.1) / 2.0)
                        );
                    }
                    let last = p(pts.len() - 1);
                    let _ = write!(d, "L{} {}", num(last.0), num(last.1));
                }
                let _ = writeln!(
                    out,
                    r#"<path d="{d}" fill="none" stroke="{stroke}" stroke-width="{}" stroke-linecap="{cap}" stroke-linejoin="round"{}/>"#,
                    num(w),
                    opacity_attr(o)
                );
            }
            ElementKind::Shape {
                shape,
                from,
                to,
                filled,
            } => {
                let (ax, ay, bx, by) = (from.x * sx, from.y * sy, to.x * sx, to.y * sy);
                let paint = if *filled {
                    format!(
                        r#"fill="{stroke}"{}"#,
                        if opacity < 1.0 {
                            format!(r#" fill-opacity="{}""#, num(opacity))
                        } else {
                            String::new()
                        }
                    )
                } else {
                    format!(
                        r#"fill="none" stroke="{stroke}" stroke-width="{}"{}"#,
                        num(width),
                        opacity_attr(opacity)
                    )
                };
                match shape {
                    ShapeKind::Rect => {
                        let _ = writeln!(
                            out,
                            r#"<rect x="{}" y="{}" width="{}" height="{}" {paint}/>"#,
                            num(ax.min(bx)),
                            num(ay.min(by)),
                            num((bx - ax).abs()),
                            num((by - ay).abs())
                        );
                    }
                    ShapeKind::Ellipse => {
                        let _ = writeln!(
                            out,
                            r#"<ellipse cx="{}" cy="{}" rx="{}" ry="{}" {paint}/>"#,
                            num((ax + bx) / 2.0),
                            num((ay + by) / 2.0),
                            num((bx - ax).abs() / 2.0),
                            num((by - ay).abs() / 2.0)
                        );
                    }
                    ShapeKind::Line | ShapeKind::Arrow => {
                        let _ = writeln!(
                            out,
                            r#"<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="{stroke}" stroke-width="{}" stroke-linecap="round"{}/>"#,
                            num(ax),
                            num(ay),
                            num(bx),
                            num(by),
                            num(width),
                            opacity_attr(opacity)
                        );
                        if *shape == ShapeKind::Arrow {
                            let [l, r] = arrow_head((ax, ay), (bx, by), width);
                            let _ = writeln!(
                                out,
                                r#"<path d="M{} {}L{} {}L{} {}Z" fill="{stroke}"/>"#,
                                num(bx),
                                num(by),
                                num(l.0),
                                num(l.1),
                                num(r.0),
                                num(r.1)
                            );
                        }
                    }
                }
            }
            ElementKind::Text { at, text, size } => {
                // Cell-space text sizes are in rows.
                let size = size * sy;
                let _ = write!(
                    out,
                    r#"<text x="{}" y="{}" font-family="ui-monospace, monospace" font-size="{}" fill="{stroke}">"#,
                    num(at.x * sx),
                    num(at.y * sy + size),
                    num(size)
                );
                for (i, line) in text.split('\n').enumerate() {
                    let dy = if i == 0 { "0".into() } else { num(size * 1.2) };
                    let _ = write!(
                        out,
                        r#"<tspan x="{}" dy="{dy}">{}</tspan>"#,
                        num(at.x * sx),
                        escape(line)
                    );
                }
                out.push_str("</text>\n");
            }
            ElementKind::Image { image, from, to } => {
                let (x, y) = (from.x.min(to.x) * sx, from.y.min(to.y) * sy);
                let (w, h) = ((to.x - from.x).abs() * sx, (to.y - from.y).abs() * sy);
                match image_href(image) {
                    Some(href) => {
                        let _ = writeln!(
                            out,
                            r#"<image x="{}" y="{}" width="{}" height="{}" href="{}"/>"#,
                            num(x),
                            num(y),
                            num(w),
                            num(h),
                            escape(&href)
                        );
                    }
                    None => {
                        let _ = writeln!(
                            out,
                            r##"<rect x="{}" y="{}" width="{}" height="{}" fill="none" stroke="#888888" stroke-dasharray="4 4"/>"##,
                            num(x),
                            num(y),
                            num(w),
                            num(h)
                        );
                    }
                }
            }
        }
    }
    out.push_str("</svg>\n");
    out
}

/// The two back corners of an arrow head at `b` pointing from `a`.
pub(crate) fn arrow_head(a: (f32, f32), b: (f32, f32), width: f32) -> [(f32, f32); 2] {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len = (dx * dx + dy * dy).sqrt().max(1e-3);
    let (ux, uy) = (dx / len, dy / len);
    let size = (width * 4.0).max(8.0).min(len);
    let (bx, by) = (b.0 - ux * size, b.1 - uy * size);
    let (px, py) = (-uy * size * 0.5, ux * size * 0.5);
    [(bx + px, by + py), (bx - px, by - py)]
}

/// A data URI for an image blob's bytes.
pub fn data_uri(media: proto::MediaType, bytes: &[u8]) -> String {
    format!(
        "data:{};base64,{}",
        media.mime(),
        data_encoding::BASE64.encode(bytes)
    )
}
