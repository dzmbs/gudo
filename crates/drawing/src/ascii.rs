//! Text rendering of a drawing: box-drawing glyphs for shapes and connectors, junctions
//! where lines meet, text as is, freehand ink as dots. For terminals without graphics and
//! for agents that read text.
//!
//! Every line is snapped to the cell grid: horizontal and vertical segments become `─` and
//! `│`, others become an elbow (horizontal first, then vertical), which keeps diagrams
//! readable and their connections exact. Rectangles get `┌┐└┘`, ellipses `╭╮╰╯`, arrow heads
//! `▶◀▲▼`.

use proto::{CoordSpace, ElementKind, ShapeKind};

use crate::points::unpack;
use crate::scene::Scene;

const UP: u8 = 1;
const DOWN: u8 = 2;
const LEFT: u8 = 4;
const RIGHT: u8 = 8;

/// Canvas units per character cell (Excalidraw's default font is 20 px high, about 10 wide).
pub const ASCII_CELL: (f32, f32) = (10.0, 20.0);

struct Grid {
    width: usize,
    height: usize,
    links: Vec<u8>,
    glyphs: Vec<Option<char>>,
}

impl Grid {
    fn index(&self, x: i64, y: i64) -> Option<usize> {
        (x >= 0 && y >= 0 && (x as usize) < self.width && (y as usize) < self.height)
            .then(|| y as usize * self.width + x as usize)
    }

    fn link(&mut self, x: i64, y: i64, bits: u8) {
        if let Some(i) = self.index(x, y) {
            self.links[i] |= bits;
        }
    }

    fn put(&mut self, x: i64, y: i64, glyph: char) {
        if let Some(i) = self.index(x, y) {
            self.glyphs[i] = Some(glyph);
        }
    }

    fn hline(&mut self, y: i64, x0: i64, x1: i64) {
        let (start, end) = (x0.min(x1), x0.max(x1));
        for x in start..=end {
            let mut bits = 0;
            if x > start {
                bits |= LEFT;
            }
            if x < end {
                bits |= RIGHT;
            }
            if start == end {
                bits = LEFT | RIGHT;
            }
            self.link(x, y, bits);
        }
    }

    fn vline(&mut self, x: i64, y0: i64, y1: i64) {
        let (start, end) = (y0.min(y1), y0.max(y1));
        for y in start..=end {
            let mut bits = 0;
            if y > start {
                bits |= UP;
            }
            if y < end {
                bits |= DOWN;
            }
            if start == end {
                bits = UP | DOWN;
            }
            self.link(x, y, bits);
        }
    }

    /// A connector from `a` to `b`: straight when aligned, else an elbow. Returns the
    /// direction of the last step (for an arrow head).
    fn connect(&mut self, a: (i64, i64), b: (i64, i64)) -> char {
        if a.1 == b.1 {
            self.hline(a.1, a.0, b.0);
        } else if a.0 == b.0 {
            self.vline(a.0, a.1, b.1);
        } else {
            self.hline(a.1, a.0, b.0);
            self.vline(b.0, a.1, b.1);
        }
        if a.0 == b.0 || a.1 != b.1 {
            if b.1 > a.1 { '▼' } else { '▲' }
        } else if b.0 > a.0 {
            '▶'
        } else {
            '◀'
        }
    }

    fn render(&self) -> String {
        let mut out = String::new();
        for y in 0..self.height {
            let mut line = String::new();
            for x in 0..self.width {
                let i = y * self.width + x;
                line.push(self.glyphs[i].unwrap_or_else(|| junction(self.links[i])));
            }
            out.push_str(line.trim_end());
            out.push('\n');
        }
        while out.ends_with("\n\n") {
            out.pop();
        }
        out
    }
}

fn junction(bits: u8) -> char {
    match bits {
        0 => ' ',
        b if b == LEFT | RIGHT || b == LEFT || b == RIGHT => '─',
        b if b == UP | DOWN || b == UP || b == DOWN => '│',
        b if b == DOWN | RIGHT => '┌',
        b if b == DOWN | LEFT => '┐',
        b if b == UP | RIGHT => '└',
        b if b == UP | LEFT => '┘',
        b if b == UP | DOWN | RIGHT => '├',
        b if b == UP | DOWN | LEFT => '┤',
        b if b == LEFT | RIGHT | DOWN => '┬',
        b if b == LEFT | RIGHT | UP => '┴',
        _ => '┼',
    }
}

/// Renders `scene` as text at most `max_cols` wide. Canvas drawings use [`ASCII_CELL`] units
/// per character (scaled down to fit); cell-space ink maps one to one.
pub fn to_ascii(scene: &Scene, space: CoordSpace, max_cols: usize) -> String {
    let Some((lo, hi)) = scene.bounds() else {
        return String::new();
    };
    let (mut cell_w, mut cell_h) = match space {
        CoordSpace::Canvas => ASCII_CELL,
        CoordSpace::Cells => (1.0, 1.0),
    };
    let cols = ((hi.x - lo.x) / cell_w).ceil() as usize + 1;
    if cols > max_cols.max(8) {
        let scale = cols as f32 / max_cols.max(8) as f32;
        cell_w *= scale;
        cell_h *= scale;
    }
    let cell = |x: f32, y: f32| {
        (
            ((x - lo.x) / cell_w).round() as i64,
            ((y - lo.y) / cell_h).round() as i64,
        )
    };
    let (last_col, last_row) = cell(hi.x, hi.y);
    let (width, height) = (last_col as usize + 2, last_row as usize + 2);
    let mut grid = Grid {
        width,
        height,
        links: vec![0; width * height],
        glyphs: vec![None; width * height],
    };
    let mut texts = Vec::new();
    let mut overlays = Vec::new();
    for element in scene.draw_order() {
        match &element.kind {
            ElementKind::Shape {
                shape,
                from,
                to,
                filled,
            } => {
                let (a, b) = (cell(from.x, from.y), cell(to.x, to.y));
                match shape {
                    ShapeKind::Rect | ShapeKind::Ellipse => {
                        if *filled && element.style.width == 0.0 {
                            // A fill under an outline: the outline draws the box.
                            continue;
                        }
                        let (x0, x1, y0, y1) =
                            (a.0.min(b.0), a.0.max(b.0), a.1.min(b.1), a.1.max(b.1));
                        grid.hline(y0, x0, x1);
                        grid.hline(y1, x0, x1);
                        grid.vline(x0, y0, y1);
                        grid.vline(x1, y0, y1);
                        if *shape == ShapeKind::Ellipse {
                            for (x, y, glyph) in
                                [(x0, y0, '╭'), (x1, y0, '╮'), (x0, y1, '╰'), (x1, y1, '╯')]
                            {
                                overlays.push((x, y, glyph));
                            }
                        }
                    }
                    ShapeKind::Line => {
                        grid.connect(a, b);
                    }
                    ShapeKind::Arrow => {
                        let head = grid.connect(a, b);
                        overlays.push((b.0, b.1, head));
                    }
                }
            }
            ElementKind::Stroke(stroke) => {
                for point in unpack(&stroke.points).unwrap_or_default() {
                    let (x, y) = cell(point.x, point.y);
                    if grid
                        .index(x, y)
                        .is_some_and(|i| grid.links[i] == 0 && grid.glyphs[i].is_none())
                    {
                        grid.put(x, y, '•');
                    }
                }
            }
            ElementKind::Text { at, text, .. } => texts.push((cell(at.x, at.y), text.clone())),
            ElementKind::Image { from, to, .. } => {
                let (a, b) = (cell(from.x, from.y), cell(to.x, to.y));
                grid.hline(a.1, a.0, b.0);
                grid.hline(b.1, a.0, b.0);
                grid.vline(a.0, a.1, b.1);
                grid.vline(b.0, a.1, b.1);
                texts.push(((a.0 + 1, a.1 + 1), "[image]".into()));
            }
        }
    }
    for (x, y, glyph) in overlays {
        grid.put(x, y, glyph);
    }
    for ((x, y), text) in texts {
        for (dy, line) in text.lines().enumerate() {
            for (dx, glyph) in line.chars().enumerate() {
                grid.put(x + dx as i64, y + dy as i64, glyph);
            }
        }
    }
    grid.render()
}
