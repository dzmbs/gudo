//! A small software rasteriser, so hosts without a GPU (headless `gudo`, the daemon's fallback
//! for "send to agent" without a client render) produce a PNG of a drawing, and so `gudo draw
//! show` can print it with kitty graphics or braille.
//!
//! Strokes are stamped as anti-aliased discs along each segment (radius from width ×
//! pressure), shapes are outlined or filled, each element composited once with its colour's
//! alpha (highlighters at 35 %). Text and images are drawn as outlines only: the app renders
//! the real thing; this is a faithful sketch of the ink.

use proto::{CoordSpace, ElementKind, ShapeKind, Tool};

use crate::points::unpack;
use crate::scene::Scene;
use crate::svg::{CELL_H, CELL_W, arrow_head};

/// An RGBA8 image, rows top to bottom.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rgba {
    /// Width in pixels.
    pub width: u32,
    pub height: u32,
    /// `width * height * 4` bytes.
    pub data: Vec<u8>,
}

/// Rendering options.
#[derive(Debug, Clone, Copy)]
pub struct RasterOptions {
    /// Pixels per unit (canvas) or per cell column width (cells).
    pub scale: f32,
    /// The longer side is clamped to this many pixels.
    pub max_side: u32,
    /// Background `0xRRGGBBAA` (`0` = transparent).
    pub background: u32,
}

impl Default for RasterOptions {
    fn default() -> Self {
        Self {
            scale: 2.0,
            max_side: 2000,
            background: 0xffff_ffff,
        }
    }
}

/// Per-pixel coverage of the element being drawn, composited once per element.
struct Coverage {
    width: usize,
    height: usize,
    coverage: Vec<f32>,
    touched: Option<(usize, usize, usize, usize)>,
}

impl Coverage {
    fn new(width: usize, height: usize) -> Self {
        Self {
            width,
            height,
            coverage: vec![0.0; width * height],
            touched: None,
        }
    }

    fn mark(&mut self, x: usize, y: usize, amount: f32) {
        let i = y * self.width + x;
        if amount > self.coverage[i] {
            self.coverage[i] = amount;
        }
        let touched = self.touched.get_or_insert((x, y, x, y));
        touched.0 = touched.0.min(x);
        touched.1 = touched.1.min(y);
        touched.2 = touched.2.max(x);
        touched.3 = touched.3.max(y);
    }

    fn disc(&mut self, cx: f32, cy: f32, radius: f32) {
        let radius = radius.max(0.5);
        let x0 = (cx - radius - 1.0).floor().max(0.0) as usize;
        let y0 = (cy - radius - 1.0).floor().max(0.0) as usize;
        let x1 = ((cx + radius + 1.0).ceil() as isize).min(self.width as isize - 1);
        let y1 = ((cy + radius + 1.0).ceil() as isize).min(self.height as isize - 1);
        if x1 < 0 || y1 < 0 {
            return;
        }
        for y in y0..=y1 as usize {
            for x in x0..=x1 as usize {
                let distance =
                    ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
                let amount = (radius + 0.5 - distance).clamp(0.0, 1.0);
                if amount > 0.0 {
                    self.mark(x, y, amount);
                }
            }
        }
    }

    fn segment(&mut self, a: (f32, f32), b: (f32, f32), radius_a: f32, radius_b: f32) {
        let length = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt();
        let steps = (length / 0.5).ceil().max(1.0) as usize;
        for i in 0..=steps {
            let t = i as f32 / steps as f32;
            self.disc(
                a.0 + (b.0 - a.0) * t,
                a.1 + (b.1 - a.1) * t,
                radius_a + (radius_b - radius_a) * t,
            );
        }
    }

    fn fill(&mut self, inside: impl Fn(f32, f32) -> bool, lo: (f32, f32), hi: (f32, f32)) {
        let x0 = lo.0.floor().max(0.0) as usize;
        let y0 = lo.1.floor().max(0.0) as usize;
        let x1 = (hi.0.ceil() as usize).min(self.width.saturating_sub(1));
        let y1 = (hi.1.ceil() as usize).min(self.height.saturating_sub(1));
        for y in y0..=y1 {
            for x in x0..=x1 {
                if inside(x as f32 + 0.5, y as f32 + 0.5) {
                    self.mark(x, y, 1.0);
                }
            }
        }
    }

    /// Blends the covered pixels into `pixels` with source-over and clears the coverage.
    fn composite(&mut self, pixels: &mut [u8], rgba: u32, alpha_scale: f32) {
        let Some((x0, y0, x1, y1)) = self.touched.take() else {
            return;
        };
        let (red, green, blue) = (
            (rgba >> 24) as f32,
            ((rgba >> 16) & 0xff) as f32,
            ((rgba >> 8) & 0xff) as f32,
        );
        let alpha = (rgba & 0xff) as f32 / 255.0 * alpha_scale;
        for y in y0..=y1 {
            for x in x0..=x1 {
                let i = y * self.width + x;
                let src_alpha = std::mem::take(&mut self.coverage[i]) * alpha;
                if src_alpha <= 0.0 {
                    continue;
                }
                let pixel = &mut pixels[i * 4..i * 4 + 4];
                let dst_alpha = f32::from(pixel[3]) / 255.0;
                let out_alpha = src_alpha + dst_alpha * (1.0 - src_alpha);
                for (channel, src) in [red, green, blue].into_iter().enumerate() {
                    let dst = f32::from(pixel[channel]);
                    let value = if out_alpha > 0.0 {
                        (src * src_alpha + dst * dst_alpha * (1.0 - src_alpha)) / out_alpha
                    } else {
                        0.0
                    };
                    pixel[channel] = value.round().clamp(0.0, 255.0) as u8;
                }
                pixel[3] = (out_alpha * 255.0).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
}

/// Rasterises a scene. An empty scene gives a 1×1 image of the background.
pub fn rasterize(scene: &Scene, space: CoordSpace, options: RasterOptions) -> Rgba {
    let (unit_x, unit_y) = match space {
        CoordSpace::Canvas => (1.0, 1.0),
        CoordSpace::Cells => (CELL_W, CELL_H),
    };
    let pad = 4.0;
    let Some((lo, hi)) = scene.bounds() else {
        return Rgba {
            width: 1,
            height: 1,
            data: options.background.to_be_bytes().to_vec(),
        };
    };
    let (mut scale_x, mut scale_y) = (unit_x * options.scale, unit_y * options.scale);
    let (scaled_w, scaled_h) = ((hi.x - lo.x) * scale_x, (hi.y - lo.y) * scale_y);
    let fit = ((options.max_side as f32 - 2.0 * pad - 1.0).max(1.0)
        / scaled_w.max(scaled_h).max(1e-3))
    .min(1.0);
    scale_x *= fit;
    scale_y *= fit;
    let width_px = (((hi.x - lo.x) * scale_x + 2.0 * pad).ceil() as usize).max(1);
    let height_px = (((hi.y - lo.y) * scale_y + 2.0 * pad).ceil() as usize).max(1);
    let map = |x: f32, y: f32| ((x - lo.x) * scale_x + pad, (y - lo.y) * scale_y + pad);
    let mut pixels: Vec<u8> = options
        .background
        .to_be_bytes()
        .iter()
        .copied()
        .cycle()
        .take(width_px * height_px * 4)
        .collect();
    let mut coverage = Coverage::new(width_px, height_px);
    for element in scene.draw_order() {
        // Widths are in x units (columns for cell-space ink).
        let width = element.style.width.max(0.0) * scale_x;
        let mut alpha = 1.0;
        match &element.kind {
            ElementKind::Stroke(stroke) => {
                let points = unpack(&stroke.points).unwrap_or_default();
                let radius = |pressure: f32| match stroke.tool {
                    Tool::Pen => width * pressure.max(0.1) / 2.0,
                    Tool::Marker | Tool::Highlighter => width / 2.0,
                };
                if stroke.tool == Tool::Highlighter {
                    alpha = 0.35;
                }
                match points.as_slice() {
                    [] => {}
                    [point] => {
                        let (x, y) = map(point.x, point.y);
                        coverage.disc(x, y, radius(point.pressure));
                    }
                    _ => {
                        for pair in points.windows(2) {
                            coverage.segment(
                                map(pair[0].x, pair[0].y),
                                map(pair[1].x, pair[1].y),
                                radius(pair[0].pressure),
                                radius(pair[1].pressure),
                            );
                        }
                    }
                }
            }
            ElementKind::Shape {
                shape,
                from,
                to,
                filled,
            } => {
                let (a, b) = (map(from.x, from.y), map(to.x, to.y));
                let radius = width / 2.0;
                let (lo, hi) = ((a.0.min(b.0), a.1.min(b.1)), (a.0.max(b.0), a.1.max(b.1)));
                match shape {
                    ShapeKind::Rect if *filled => coverage.fill(|_, _| true, lo, hi),
                    ShapeKind::Rect => {
                        let corners = [lo, (hi.0, lo.1), hi, (lo.0, hi.1), lo];
                        for edge in corners.windows(2) {
                            coverage.segment(edge[0], edge[1], radius, radius);
                        }
                    }
                    ShapeKind::Ellipse => {
                        let (cx, cy) = ((lo.0 + hi.0) / 2.0, (lo.1 + hi.1) / 2.0);
                        let (rx, ry) = (
                            ((hi.0 - lo.0) / 2.0).max(0.5),
                            ((hi.1 - lo.1) / 2.0).max(0.5),
                        );
                        if *filled {
                            coverage.fill(
                                |x, y| ((x - cx) / rx).powi(2) + ((y - cy) / ry).powi(2) <= 1.0,
                                lo,
                                hi,
                            );
                        } else {
                            let rim = |i: usize| {
                                let angle = i as f32 / 64.0 * std::f32::consts::TAU;
                                (cx + rx * angle.cos(), cy + ry * angle.sin())
                            };
                            for i in 0..64 {
                                coverage.segment(rim(i), rim(i + 1), radius, radius);
                            }
                        }
                    }
                    ShapeKind::Line | ShapeKind::Arrow => {
                        coverage.segment(a, b, radius, radius);
                        if *shape == ShapeKind::Arrow {
                            for corner in arrow_head(a, b, width) {
                                coverage.segment(b, corner, radius, radius);
                            }
                        }
                    }
                }
            }
            ElementKind::Text { at, text, size } => {
                let lines = text.lines().count().max(1) as f32;
                let cols = text
                    .lines()
                    .map(|line| line.chars().count())
                    .max()
                    .unwrap_or(0) as f32;
                let (a, b) = (
                    map(at.x, at.y),
                    map(at.x + cols * size * 0.6, at.y + lines * size * 1.2),
                );
                // A baseline per line stands in for the glyphs.
                for i in 0..lines as usize {
                    let y = a.1 + (b.1 - a.1) * (i as f32 + 0.9) / lines;
                    coverage.segment((a.0, y), (b.0, y), 0.75, 0.75);
                }
            }
            ElementKind::Image { from, to, .. } => {
                let (a, b) = (map(from.x, from.y), map(to.x, to.y));
                let corners = [a, (b.0, a.1), b, (a.0, b.1), a];
                for edge in corners.windows(2) {
                    coverage.segment(edge[0], edge[1], 0.75, 0.75);
                }
            }
        }
        coverage.composite(&mut pixels, element.style.color, alpha);
    }
    Rgba {
        width: width_px as u32,
        height: height_px as u32,
        data: pixels,
    }
}

/// Renders the image as braille (2×4 dots per character), dark pixels set, at most `cols`
/// characters wide. For terminals without kitty graphics.
pub fn braille(image: &Rgba, cols: usize) -> String {
    let (width, height) = (image.width as usize, image.height as usize);
    let cols = cols.max(1);
    let step = (width as f32 / (cols * 2) as f32).max(1.0);
    let dots_w = ((width as f32 / step).ceil() as usize).max(1);
    let dots_h = ((height as f32 / step).ceil() as usize).max(1);
    let dark = |dot_x: usize, dot_y: usize| -> bool {
        let (x0, y0) = (
            (dot_x as f32 * step) as usize,
            (dot_y as f32 * step) as usize,
        );
        let (x1, y1) = (
            (((dot_x + 1) as f32 * step) as usize).min(width),
            (((dot_y + 1) as f32 * step) as usize).min(height),
        );
        for y in y0..y1.max(y0 + 1).min(height) {
            for x in x0..x1.max(x0 + 1).min(width) {
                let offset = (y * width + x) * 4;
                let pixel = &image.data[offset..offset + 4];
                let luma =
                    (u32::from(pixel[0]) * 3 + u32::from(pixel[1]) * 6 + u32::from(pixel[2])) / 10;
                if pixel[3] > 64 && luma < 160 {
                    return true;
                }
            }
        }
        false
    };
    const BITS: [[u32; 2]; 4] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]];
    let mut out = String::new();
    for char_row in 0..dots_h.div_ceil(4) {
        let mut line = String::new();
        for char_col in 0..dots_w.div_ceil(2) {
            let mut bits = 0;
            for (row, row_bits) in BITS.iter().enumerate() {
                for (col, bit) in row_bits.iter().enumerate() {
                    if dark(char_col * 2 + col, char_row * 4 + row) {
                        bits |= bit;
                    }
                }
            }
            line.push(char::from_u32(0x2800 + bits).unwrap_or(' '));
        }
        out.push_str(line.trim_end_matches('\u{2800}'));
        out.push('\n');
    }
    out
}
