//! Ink points and their packed wire form ([`PackedPoints`]), plus stroke simplification.
//!
//!
//! ```text
//! 0x01
//! per point: zigzag-varint dx, zigzag-varint dy    (1/32 unit; the first point is relative to 0,0)
//!            u8 pressure                           (0..=255 ↔ 0.0..=1.0)
//!            u8 altitude                           (0..=255 ↔ 0..=π/2, 255 = pen upright)
//!            u8 azimuth                            (0..=255 ↔ 0..2π)
//!            varint dt                             (ms since the previous point; first: since stroke start)
//! ```
//!
//! A typical Pencil point (moving a few units per 4 ms sample) packs to 6–7 bytes, against 24
//! for six `f32`s.

use std::f32::consts::{FRAC_PI_2, TAU};

use proto::PackedPoints;

/// Coordinates are quantised to this fraction of a unit.
pub const QUANTUM: f32 = 1.0 / 32.0;
/// Most points one stroke may have.
pub const MAX_POINTS: usize = 65_536;
const VERSION: u8 = 1;

/// One sampled pen position.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InkPoint {
    /// x, in the drawing's units.
    pub x: f32,
    /// y.
    pub y: f32,
    /// Force, 0..=1 (1 for a mouse or finger).
    pub pressure: f32,
    /// Pen altitude in radians, 0 (flat) ..= π/2 (upright).
    pub altitude: f32,
    /// Pen azimuth in radians, 0..2π.
    pub azimuth: f32,
    /// Milliseconds since the stroke started.
    pub t_ms: u32,
}

impl InkPoint {
    /// A point with full pressure, an upright pen, at time `t_ms`.
    pub fn at(x: f32, y: f32, t_ms: u32) -> Self {
        Self {
            x,
            y,
            pressure: 1.0,
            altitude: FRAC_PI_2,
            azimuth: 0.0,
            t_ms,
        }
    }
}

/// Why packed points could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PointsError {
    /// Unknown format version.
    Version(u8),
    /// Ended inside a point.
    Truncated,
    /// More than [`MAX_POINTS`].
    TooMany,
}

impl std::fmt::Display for PointsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Version(v) => write!(f, "unknown packed points version {v}"),
            Self::Truncated => f.write_str("packed points truncated"),
            Self::TooMany => write!(f, "more than {MAX_POINTS} points"),
        }
    }
}

impl std::error::Error for PointsError {}

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn get_varint(data: &[u8], pos: &mut usize) -> Result<u64, PointsError> {
    let mut v = 0u64;
    for shift in (0..64).step_by(7) {
        let b = *data.get(*pos).ok_or(PointsError::Truncated)?;
        *pos += 1;
        v |= u64::from(b & 0x7f) << shift;
        if b & 0x80 == 0 {
            return Ok(v);
        }
    }
    Err(PointsError::Truncated)
}

fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

fn unzigzag(v: u64) -> i64 {
    ((v >> 1) as i64) ^ -((v & 1) as i64)
}

fn quantise(v: f32) -> i64 {
    if v.is_finite() {
        (v / QUANTUM).round().clamp(-1e12, 1e12) as i64
    } else {
        0
    }
}

fn unit_byte(v: f32, full: f32) -> u8 {
    if v.is_finite() {
        (v / full * 255.0).round().clamp(0.0, 255.0) as u8
    } else {
        255
    }
}

/// Packs points (see the module docs). Coordinates are rounded to [`QUANTUM`].
///
/// # Examples
///
/// ```
/// use drawing::{InkPoint, pack, unpack};
///
/// let pts = [InkPoint::at(10.0, 4.0, 0), InkPoint::at(10.5, 4.25, 4)];
/// let packed = pack(&pts);
/// assert_eq!(unpack(&packed).unwrap(), pts);
/// ```
pub fn pack(points: &[InkPoint]) -> PackedPoints {
    let mut out = Vec::with_capacity(1 + points.len() * 7);
    out.push(VERSION);
    let (mut px, mut py, mut pt) = (0i64, 0i64, 0u32);
    for p in points {
        let (x, y) = (quantise(p.x), quantise(p.y));
        put_varint(&mut out, zigzag(x - px));
        put_varint(&mut out, zigzag(y - py));
        out.push(unit_byte(p.pressure, 1.0));
        out.push(unit_byte(p.altitude, FRAC_PI_2));
        let az = if p.azimuth.is_finite() {
            (p.azimuth.rem_euclid(TAU) / TAU * 256.0).round() as u32 % 256
        } else {
            0
        };
        out.push(az as u8);
        put_varint(&mut out, u64::from(p.t_ms.saturating_sub(pt)));
        (px, py, pt) = (x, y, p.t_ms.max(pt));
    }
    PackedPoints(out)
}

/// Unpacks points.
///
/// # Errors
///
/// [`PointsError`] for an unknown version, truncated data or too many points.
pub fn unpack(packed: &PackedPoints) -> Result<Vec<InkPoint>, PointsError> {
    let data = &packed.0;
    let Some(&version) = data.first() else {
        return Ok(Vec::new());
    };
    if version != VERSION {
        return Err(PointsError::Version(version));
    }
    let mut pos = 1;
    let mut out = Vec::new();
    let (mut x, mut y, mut t) = (0i64, 0i64, 0u64);
    while pos < data.len() {
        if out.len() >= MAX_POINTS {
            return Err(PointsError::TooMany);
        }
        x += unzigzag(get_varint(data, &mut pos)?);
        y += unzigzag(get_varint(data, &mut pos)?);
        let bytes = data.get(pos..pos + 3).ok_or(PointsError::Truncated)?;
        pos += 3;
        t += get_varint(data, &mut pos)?;
        out.push(InkPoint {
            x: x as f32 * QUANTUM,
            y: y as f32 * QUANTUM,
            pressure: f32::from(bytes[0]) / 255.0,
            altitude: f32::from(bytes[1]) / 255.0 * FRAC_PI_2,
            azimuth: f32::from(bytes[2]) / 256.0 * TAU,
            t_ms: u32::try_from(t).unwrap_or(u32::MAX),
        });
    }
    Ok(out)
}

/// Number of points in packed data without decoding them fully, or `None` if malformed.
pub fn count(packed: &PackedPoints) -> Option<usize> {
    unpack(packed).ok().map(|p| p.len())
}

/// Ramer–Douglas–Peucker simplification for committed strokes: drops points closer than
/// `epsilon` to the line through their neighbours, keeping both ends and every point whose
/// pressure differs from the kept neighbours' interpolation by more than 0.1 (so pressure
/// swells survive).
pub fn simplify(points: &[InkPoint], epsilon: f32) -> Vec<InkPoint> {
    if points.len() <= 2 || epsilon <= 0.0 {
        return points.to_vec();
    }
    let mut keep = vec![false; points.len()];
    keep[0] = true;
    keep[points.len() - 1] = true;
    let mut stack = vec![(0, points.len() - 1)];
    while let Some((a, b)) = stack.pop() {
        if b <= a + 1 {
            continue;
        }
        let (pa, pb) = (points[a], points[b]);
        let mut worst = (0.0f32, 0usize);
        for (i, p) in points.iter().enumerate().take(b).skip(a + 1) {
            let d = segment_distance(*p, pa, pb);
            let f = (i - a) as f32 / (b - a) as f32;
            let expected = pa.pressure + (pb.pressure - pa.pressure) * f;
            let score = if (p.pressure - expected).abs() > 0.1 {
                f32::INFINITY
            } else {
                d
            };
            if score > worst.0 {
                worst = (score, i);
            }
        }
        if worst.0 > epsilon {
            keep[worst.1] = true;
            stack.push((a, worst.1));
            stack.push((worst.1, b));
        }
    }
    points
        .iter()
        .zip(keep)
        .filter_map(|(p, k)| k.then_some(*p))
        .collect()
}

fn segment_distance(p: InkPoint, a: InkPoint, b: InkPoint) -> f32 {
    let (dx, dy) = (b.x - a.x, b.y - a.y);
    let len2 = dx * dx + dy * dy;
    let t = if len2 == 0.0 {
        0.0
    } else {
        (((p.x - a.x) * dx + (p.y - a.y) * dy) / len2).clamp(0.0, 1.0)
    };
    let (cx, cy) = (a.x + t * dx, a.y + t * dy);
    ((p.x - cx).powi(2) + (p.y - cy).powi(2)).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_within_quantum() {
        let pts: Vec<InkPoint> = (0..200)
            .map(|i| InkPoint {
                x: 100.0 + i as f32 * 0.37,
                y: -20.0 + (i as f32 / 7.0).sin() * 30.0,
                pressure: (i % 10) as f32 / 9.0,
                altitude: 1.0,
                azimuth: 4.0,
                t_ms: i * 4,
            })
            .collect();
        let packed = pack(&pts);
        let back = unpack(&packed).unwrap();
        assert_eq!(back.len(), pts.len());
        for (a, b) in pts.iter().zip(&back) {
            assert!((a.x - b.x).abs() <= QUANTUM / 2.0 + 1e-4);
            assert!((a.y - b.y).abs() <= QUANTUM / 2.0 + 1e-4);
            assert!((a.pressure - b.pressure).abs() <= 1.0 / 255.0);
            assert!((a.altitude - b.altitude).abs() < 0.01);
            assert!((a.azimuth - b.azimuth).abs() < 0.03);
            assert_eq!(a.t_ms, b.t_ms);
        }
        // About 6–7 bytes a point for a smooth stroke.
        assert!(packed.0.len() < pts.len() * 8, "{}", packed.0.len());
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(
            unpack(&PackedPoints(vec![2, 0])),
            Err(PointsError::Version(2))
        );
        assert_eq!(
            unpack(&PackedPoints(vec![1, 0, 0, 1])),
            Err(PointsError::Truncated)
        );
        assert_eq!(unpack(&PackedPoints(vec![])).unwrap(), vec![]);
    }

    #[test]
    fn simplify_keeps_corners_and_ends() {
        let mut pts: Vec<InkPoint> = (0..50).map(|i| InkPoint::at(i as f32, 0.0, i)).collect();
        pts.extend((1..50).map(|i| InkPoint::at(49.0, i as f32, 50 + i)));
        let s = simplify(&pts, 0.25);
        assert_eq!(s.len(), 3);
        assert_eq!(s[1].x, 49.0);
        assert_eq!(s[1].y, 0.0);
    }
}
