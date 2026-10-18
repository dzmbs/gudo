//! A small software rasteriser, so hosts without a GPU (headless `un`, the daemon's fallback
//! for "send to agent" without a client render) produce a PNG of a drawing, and so `un draw
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
    /// Height.
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

struct Coverage {
    w: usize,
    h: usize,
    cov: Vec<f32>,
    touched: Option<(usize, usize, usize, usize)>,
}

impl Coverage {
    fn new(w: usize, h: usize) -> Self {
        Self {
            w,
            h,
            cov: vec![0.0; w * h],
            touched: None,
        }
    }

    fn mark(&mut self, x: usize, y: usize, c: f32) {
        let i = y * self.w + x;
        if c > self.cov[i] {
            self.cov[i] = c;
        }
        let t = self.touched.get_or_insert((x, y, x, y));
        t.0 = t.0.min(x);
        t.1 = t.1.min(y);
        t.2 = t.2.max(x);
        t.3 = t.3.max(y);
    }

    fn disc(&mut self, cx: f32, cy: f32, r: f32) {
        let r = r.max(0.5);
        let x0 = (cx - r - 1.0).floor().max(0.0) as usize;
        let y0 = (cy - r - 1.0).floor().max(0.0) as usize;
        let x1 = ((cx + r + 1.0).ceil() as isize).min(self.w as isize - 1);
        let y1 = ((cy + r + 1.0).ceil() as isize).min(self.h as isize - 1);
        if x1 < 0 || y1 < 0 {
            return;
        }
        for y in y0..=y1 as usize {
            for x in x0..=x1 as usize {
                let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
                let c = (r + 0.5 - d).clamp(0.0, 1.0);
                if c > 0.0 {
                    self.mark(x, y, c);
                }
            }
        }
    }

    fn segment(&mut self, a: (f32, f32), b: (f32, f32), ra: f32, rb: f32) {
        let len = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt();
        let steps = (len / 0.5).ceil().max(1.0) as usize;
        for i in 0..=steps {
            let t = i as f32 / steps as f32;
            self.disc(
                a.0 + (b.0 - a.0) * t,
                a.1 + (b.1 - a.1) * t,
                ra + (rb - ra) * t,
            );
        }
    }

    fn fill(&mut self, inside: impl Fn(f32, f32) -> bool, lo: (f32, f32), hi: (f32, f32)) {
        let x0 = lo.0.floor().max(0.0) as usize;
        let y0 = lo.1.floor().max(0.0) as usize;
        let x1 = (hi.0.ceil() as usize).min(self.w.saturating_sub(1));
        let y1 = (hi.1.ceil() as usize).min(self.h.saturating_sub(1));
        for y in y0..=y1 {
            for x in x0..=x1 {
                if inside(x as f32 + 0.5, y as f32 + 0.5) {
                    self.mark(x, y, 1.0);
                }
            }
        }
    }

    fn composite(&mut self, img: &mut [u8], rgba: u32, alpha_scale: f32) {
        let Some((x0, y0, x1, y1)) = self.touched.take() else {
            return;
        };
        let (r, g, b) = (
            (rgba >> 24) as f32,
            ((rgba >> 16) & 0xff) as f32,
            ((rgba >> 8) & 0xff) as f32,
        );
        let a = (rgba & 0xff) as f32 / 255.0 * alpha_scale;
        for y in y0..=y1 {
            for x in x0..=x1 {
                let i = y * self.w + x;
                let c = std::mem::take(&mut self.cov[i]) * a;
                if c <= 0.0 {
                    continue;
                }
                let p = &mut img[i * 4..i * 4 + 4];
                let da = f32::from(p[3]) / 255.0;
                let oa = c + da * (1.0 - c);
                for (k, src) in [r, g, b].into_iter().enumerate() {
                    let dst = f32::from(p[k]);
                    let v = if oa > 0.0 {
                        (src * c + dst * da * (1.0 - c)) / oa
                    } else {
                        0.0
                    };
                    p[k] = v.round().clamp(0.0, 255.0) as u8;
                }
                p[3] = (oa * 255.0).round().clamp(0.0, 255.0) as u8;
            }
        }
    }
}

/// Rasterises a scene. An empty scene gives a 1×1 image of the background.
pub fn rasterize(scene: &Scene, space: CoordSpace, opts: RasterOptions) -> Rgba {
    let (ux, uy) = match space {
        CoordSpace::Canvas => (1.0, 1.0),
        CoordSpace::Cells => (CELL_W, CELL_H),
    };
    let pad = 4.0;
    let Some((lo, hi)) = scene.bounds() else {
        return Rgba {
            width: 1,
            height: 1,
            data: opts.background.to_be_bytes().to_vec(),
        };
    };
    let (mut sx, mut sy) = (ux * opts.scale, uy * opts.scale);
    let (bw, bh) = ((hi.x - lo.x) * sx, (hi.y - lo.y) * sy);
    let fit = ((opts.max_side as f32 - 2.0 * pad - 1.0).max(1.0) / bw.max(bh).max(1e-3)).min(1.0);
    sx *= fit;
    sy *= fit;
    let w = (((hi.x - lo.x) * sx + 2.0 * pad).ceil() as usize).max(1);
    let h = (((hi.y - lo.y) * sy + 2.0 * pad).ceil() as usize).max(1);
    let map = |x: f32, y: f32| ((x - lo.x) * sx + pad, (y - lo.y) * sy + pad);
    // Widths are in x units (columns for cell-space ink).
    let wscale = sx;
    let mut img: Vec<u8> = opts
        .background
        .to_be_bytes()
        .iter()
        .copied()
        .cycle()
        .take(w * h * 4)
        .collect();
    let mut cov = Coverage::new(w, h);
    for e in scene.draw_order() {
        let width = e.style.width.max(0.0) * wscale;
        let mut alpha = 1.0;
        match &e.kind {
            ElementKind::Stroke(s) => {
                let pts = unpack(&s.points).unwrap_or_default();
                let radius = |p: f32| match s.tool {
                    Tool::Pen => width * p.max(0.1) / 2.0,
                    Tool::Marker | Tool::Highlighter => width / 2.0,
                };
                if s.tool == Tool::Highlighter {
                    alpha = 0.35;
                }
                match pts.as_slice() {
                    [] => {}
                    [p] => {
                        let (x, y) = map(p.x, p.y);
                        cov.disc(x, y, radius(p.pressure));
                    }
                    _ => {
                        for pair in pts.windows(2) {
                            cov.segment(
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
                let r = width / 2.0;
                let (lo, hi) = ((a.0.min(b.0), a.1.min(b.1)), (a.0.max(b.0), a.1.max(b.1)));
                match shape {
                    ShapeKind::Rect if *filled => cov.fill(|_, _| true, lo, hi),
                    ShapeKind::Rect => {
                        let c = [lo, (hi.0, lo.1), hi, (lo.0, hi.1), lo];
                        for s in c.windows(2) {
                            cov.segment(s[0], s[1], r, r);
                        }
                    }
                    ShapeKind::Ellipse => {
                        let (cx, cy) = ((lo.0 + hi.0) / 2.0, (lo.1 + hi.1) / 2.0);
                        let (rx, ry) = (
                            ((hi.0 - lo.0) / 2.0).max(0.5),
                            ((hi.1 - lo.1) / 2.0).max(0.5),
                        );
                        if *filled {
                            cov.fill(
                                |x, y| ((x - cx) / rx).powi(2) + ((y - cy) / ry).powi(2) <= 1.0,
                                lo,
                                hi,
                            );
                        } else {
                            let pt = |i: usize| {
                                let t = i as f32 / 64.0 * std::f32::consts::TAU;
                                (cx + rx * t.cos(), cy + ry * t.sin())
                            };
                            for i in 0..64 {
                                cov.segment(pt(i), pt(i + 1), r, r);
                            }
                        }
                    }
                    ShapeKind::Line | ShapeKind::Arrow => {
                        cov.segment(a, b, r, r);
                        if *shape == ShapeKind::Arrow {
                            for corner in arrow_head(a, b, width) {
                                cov.segment(b, corner, r, r);
                            }
                        }
                    }
                }
            }
            ElementKind::Text { at, text, size } => {
                let lines = text.lines().count().max(1) as f32;
                let cols = text.lines().map(|l| l.chars().count()).max().unwrap_or(0) as f32;
                let (a, b) = (
                    map(at.x, at.y),
                    map(at.x + cols * size * 0.6, at.y + lines * size * 1.2),
                );
                // A baseline per line stands in for the glyphs.
                for i in 0..lines as usize {
                    let y = a.1 + (b.1 - a.1) * (i as f32 + 0.9) / lines;
                    cov.segment((a.0, y), (b.0, y), 0.75, 0.75);
                }
            }
            ElementKind::Image { from, to, .. } => {
                let (a, b) = (map(from.x, from.y), map(to.x, to.y));
                let c = [a, (b.0, a.1), b, (a.0, b.1), a];
                for s in c.windows(2) {
                    cov.segment(s[0], s[1], 0.75, 0.75);
                }
            }
        }
        cov.composite(&mut img, e.style.color, alpha);
    }
    Rgba {
        width: w as u32,
        height: h as u32,
        data: img,
    }
}

/// Renders the image as braille (2×4 dots per character), dark pixels set, at most `cols`
/// characters wide. For terminals without kitty graphics.
pub fn braille(img: &Rgba, cols: usize) -> String {
    let (w, h) = (img.width as usize, img.height as usize);
    let cols = cols.max(1);
    let step = (w as f32 / (cols * 2) as f32).max(1.0);
    let dots_w = ((w as f32 / step).ceil() as usize).max(1);
    let dots_h = ((h as f32 / step).ceil() as usize).max(1);
    let dark = |dx: usize, dy: usize| -> bool {
        let (x0, y0) = ((dx as f32 * step) as usize, (dy as f32 * step) as usize);
        let (x1, y1) = (
            (((dx + 1) as f32 * step) as usize).min(w),
            (((dy + 1) as f32 * step) as usize).min(h),
        );
        for y in y0..y1.max(y0 + 1).min(h) {
            for x in x0..x1.max(x0 + 1).min(w) {
                let p = &img.data[(y * w + x) * 4..(y * w + x) * 4 + 4];
                let lum = (u32::from(p[0]) * 3 + u32::from(p[1]) * 6 + u32::from(p[2])) / 10;
                if p[3] > 64 && lum < 160 {
                    return true;
                }
            }
        }
        false
    };
    const BITS: [[u32; 2]; 4] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]];
    let mut out = String::new();
    for cy in 0..dots_h.div_ceil(4) {
        let mut line = String::new();
        for cx in 0..dots_w.div_ceil(2) {
            let mut bits = 0;
            for (row, row_bits) in BITS.iter().enumerate() {
                for (col, bit) in row_bits.iter().enumerate() {
                    if dark(cx * 2 + col, cy * 4 + row) {
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
