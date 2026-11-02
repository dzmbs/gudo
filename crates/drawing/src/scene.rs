//! Materialising a drawing from its op log.

use proto::{DrawOp, Element, ElementId, ElementKind, OpBatch, Pt};

use crate::points::unpack;

/// A drawing's elements at one version, in insertion order.
///
/// Applying the same batches in the same order always gives the same scene, which is what
/// makes every client converge: the daemon orders batches and numbers them.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Scene {
    /// The version the elements reflect.
    pub version: u64,
    /// The title as last set by [`DrawOp::SetTitle`] (if any).
    pub title: Option<String>,
    elements: Vec<Element>,
}

/// A batch could not be applied in order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VersionGap {
    /// The version the scene has.
    pub have: u64,
    /// The batch's version.
    pub got: u64,
}

impl Scene {
    /// An empty scene at version 0.
    pub fn new() -> Self {
        Self::default()
    }

    /// A scene holding `elements` at `version` (a full scene from the daemon).
    pub fn from_elements(version: u64, elements: Vec<Element>) -> Self {
        Self {
            version,
            title: None,
            elements,
        }
    }

    /// Elements in insertion order.
    pub fn elements(&self) -> &[Element] {
        &self.elements
    }

    /// Elements in drawing order: by `z`, ties in insertion order.
    pub fn draw_order(&self) -> Vec<&Element> {
        let mut ordered: Vec<&Element> = self.elements.iter().collect();
        ordered.sort_by_key(|element| element.z);
        ordered
    }

    /// Applies ops without touching the version.
    pub fn apply_ops(&mut self, ops: &[DrawOp]) {
        for op in ops {
            self.apply_op(op);
        }
    }

    fn find(&mut self, id: ElementId) -> Option<&mut Element> {
        self.elements.iter_mut().find(|element| element.id == id)
    }

    fn apply_op(&mut self, op: &DrawOp) {
        match op {
            DrawOp::Add(element) => match self.find(element.id) {
                Some(existing) => *existing = element.clone(),
                None => self.elements.push(element.clone()),
            },
            DrawOp::Move { id, dx, dy } => {
                if let Some(element) = self.find(*id) {
                    translate(element, *dx, *dy);
                }
            }
            DrawOp::Restyle { id, style } => {
                if let Some(element) = self.find(*id) {
                    element.style = *style;
                }
            }
            DrawOp::SetZ { id, z } => {
                if let Some(element) = self.find(*id) {
                    element.z = *z;
                }
            }
            DrawOp::Delete { id } => self.elements.retain(|element| element.id != *id),
            DrawOp::Clear => self.elements.clear(),
            DrawOp::SetTitle(title) => self.title = Some(title.clone()),
        }
    }

    /// Applies the next batch.
    ///
    /// # Errors
    ///
    /// [`VersionGap`] unless `batch.version == self.version + 1` (an older batch is ignored
    /// and reported as a gap too, so the caller can tell; the scene is unchanged).
    pub fn apply(&mut self, batch: &OpBatch) -> Result<(), VersionGap> {
        if batch.version != self.version + 1 {
            return Err(VersionGap {
                have: self.version,
                got: batch.version,
            });
        }
        self.apply_ops(&batch.ops);
        self.version = batch.version;
        Ok(())
    }

    /// The bounding box `(min, max)` of every element, widths included; `None` when empty.
    pub fn bounds(&self) -> Option<(Pt, Pt)> {
        let mut bounds: Option<(Pt, Pt)> = None;
        let mut add = |x: f32, y: f32, pad: f32| {
            if !(x.is_finite() && y.is_finite()) {
                return;
            }
            let (lo, hi) = bounds.get_or_insert((Pt { x, y }, Pt { x, y }));
            lo.x = lo.x.min(x - pad);
            lo.y = lo.y.min(y - pad);
            hi.x = hi.x.max(x + pad);
            hi.y = hi.y.max(y + pad);
        };
        for element in &self.elements {
            let pad = element.style.width.max(0.0) / 2.0;
            match &element.kind {
                ElementKind::Stroke(stroke) => {
                    for point in unpack(&stroke.points).unwrap_or_default() {
                        add(point.x, point.y, pad);
                    }
                }
                ElementKind::Shape { from, to, .. } | ElementKind::Image { from, to, .. } => {
                    add(from.x, from.y, pad);
                    add(to.x, to.y, pad);
                }
                ElementKind::Text { at, text, size } => {
                    let lines = text.lines().count().max(1) as f32;
                    let cols = text
                        .lines()
                        .map(|line| line.chars().count())
                        .max()
                        .unwrap_or(0) as f32;
                    add(at.x, at.y, 0.0);
                    // Rough monospace advance and line height relative to font size.
                    add(at.x + cols * size * 0.6, at.y + lines * size * 1.2, 0.0);
                }
            }
        }
        bounds
    }
}

fn translate(element: &mut Element, dx: f32, dy: f32) {
    let shift = |point: &mut Pt| {
        point.x += dx;
        point.y += dy;
    };
    match &mut element.kind {
        ElementKind::Stroke(stroke) => {
            if let Ok(mut points) = unpack(&stroke.points) {
                for point in &mut points {
                    point.x += dx;
                    point.y += dy;
                }
                stroke.points = crate::points::pack(&points);
            }
        }
        ElementKind::Shape { from, to, .. } | ElementKind::Image { from, to, .. } => {
            shift(from);
            shift(to);
        }
        ElementKind::Text { at, .. } => shift(at),
    }
}
