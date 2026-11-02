//! Ink points and their packed wire form ([`PackedPoints`]), plus stroke simplification.
//!
//! Packed format, version 1:
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
            Self::Version(version) => write!(f, "unknown packed points version {version}"),
            Self::Truncated => f.write_str("packed points truncated"),
            Self::TooMany => write!(f, "more than {MAX_POINTS} points"),
        }
    }
}

impl std::error::Error for PointsError {}

fn put_varint(out: &mut Vec<u8>, mut value: u64) {
    while value >= 0x80 {
        out.push((value as u8) | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

fn get_varint(data: &[u8], pos: &mut usize) -> Result<u64, PointsError> {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let byte = *data.get(*pos).ok_or(PointsError::Truncated)?;
        *pos += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err(PointsError::Truncated)
}

fn zigzag(value: i64) -> u64 {
    ((value << 1) ^ (value >> 63)) as u64
}

fn unzigzag(value: u64) -> i64 {
    ((value >> 1) as i64) ^ -((value & 1) as i64)
}

fn quantise(value: f32) -> i64 {
    if value.is_finite() {
        (value / QUANTUM).round().clamp(-1e12, 1e12) as i64
    } else {
        0
    }
}

fn unit_byte(value: f32, full: f32) -> u8 {
    if value.is_finite() {
        (value / full * 255.0).round().clamp(0.0, 255.0) as u8
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
    let (mut prev_x, mut prev_y, mut prev_ms) = (0i64, 0i64, 0u32);
    for point in points {
        let (x, y) = (quantise(point.x), quantise(point.y));
        put_varint(&mut out, zigzag(x - prev_x));
        put_varint(&mut out, zigzag(y - prev_y));
        out.push(unit_byte(point.pressure, 1.0));
        out.push(unit_byte(point.altitude, FRAC_PI_2));
        let azimuth = if point.azimuth.is_finite() {
            (point.azimuth.rem_euclid(TAU) / TAU * 256.0).round() as u32 % 256
        } else {
            0
        };
        out.push(azimuth as u8);
        put_varint(&mut out, u64::from(point.t_ms.saturating_sub(prev_ms)));
        (prev_x, prev_y, prev_ms) = (x, y, point.t_ms.max(prev_ms));
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
    let (mut x, mut y, mut elapsed_ms) = (0i64, 0i64, 0u64);
    while pos < data.len() {
        if out.len() >= MAX_POINTS {
            return Err(PointsError::TooMany);
        }
        x += unzigzag(get_varint(data, &mut pos)?);
        y += unzigzag(get_varint(data, &mut pos)?);
        let pen = data.get(pos..pos + 3).ok_or(PointsError::Truncated)?;
        pos += 3;
        elapsed_ms += get_varint(data, &mut pos)?;
        out.push(InkPoint {
            x: x as f32 * QUANTUM,
            y: y as f32 * QUANTUM,
            pressure: f32::from(pen[0]) / 255.0,
            altitude: f32::from(pen[1]) / 255.0 * FRAC_PI_2,
            azimuth: f32::from(pen[2]) / 256.0 * TAU,
            t_ms: u32::try_from(elapsed_ms).unwrap_or(u32::MAX),
        });
    }
    Ok(out)
}

/// Number of points in packed data without decoding them fully, or `None` if malformed.
pub fn count(packed: &PackedPoints) -> Option<usize> {
    unpack(packed).ok().map(|points| points.len())
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
    while let Some((start, end)) = stack.pop() {
        if end <= start + 1 {
            continue;
        }
        let (first, last) = (points[start], points[end]);
        let (mut worst_score, mut worst_index) = (0.0f32, 0usize);
        for (i, point) in points.iter().enumerate().take(end).skip(start + 1) {
            let distance = segment_distance(*point, first, last);
            let fraction = (i - start) as f32 / (end - start) as f32;
            let expected = first.pressure + (last.pressure - first.pressure) * fraction;
            let score = if (point.pressure - expected).abs() > 0.1 {
                f32::INFINITY
            } else {
                distance
            };
            if score > worst_score {
                (worst_score, worst_index) = (score, i);
            }
        }
        if worst_score > epsilon {
            keep[worst_index] = true;
            stack.push((start, worst_index));
            stack.push((worst_index, end));
        }
    }
    points
        .iter()
        .zip(keep)
        .filter_map(|(point, kept)| kept.then_some(*point))
        .collect()
}

fn segment_distance(point: InkPoint, a: InkPoint, b: InkPoint) -> f32 {
    let (dx, dy) = (b.x - a.x, b.y - a.y);
    let length_sq = dx * dx + dy * dy;
    let along = if length_sq == 0.0 {
        0.0
    } else {
        (((point.x - a.x) * dx + (point.y - a.y) * dy) / length_sq).clamp(0.0, 1.0)
    };
    let (closest_x, closest_y) = (a.x + along * dx, a.y + along * dy);
    ((point.x - closest_x).powi(2) + (point.y - closest_y).powi(2)).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_within_quantum() {
        let points: Vec<InkPoint> = (0..200)
            .map(|i| InkPoint {
                x: 100.0 + i as f32 * 0.37,
                y: -20.0 + (i as f32 / 7.0).sin() * 30.0,
                pressure: (i % 10) as f32 / 9.0,
                altitude: 1.0,
                azimuth: 4.0,
                t_ms: i * 4,
            })
            .collect();
        let packed = pack(&points);
        let decoded = unpack(&packed).unwrap();
        assert_eq!(decoded.len(), points.len());
        for (a, b) in points.iter().zip(&decoded) {
            assert!((a.x - b.x).abs() <= QUANTUM / 2.0 + 1e-4);
            assert!((a.y - b.y).abs() <= QUANTUM / 2.0 + 1e-4);
            assert!((a.pressure - b.pressure).abs() <= 1.0 / 255.0);
            assert!((a.altitude - b.altitude).abs() < 0.01);
            assert!((a.azimuth - b.azimuth).abs() < 0.03);
            assert_eq!(a.t_ms, b.t_ms);
        }
        assert!(packed.0.len() < points.len() * 8, "{}", packed.0.len());
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
        let mut points: Vec<InkPoint> = (0..50).map(|i| InkPoint::at(i as f32, 0.0, i)).collect();
        points.extend((1..50).map(|i| InkPoint::at(49.0, i as f32, 50 + i)));
        let simplified = simplify(&points, 0.25);
        assert_eq!(simplified.len(), 3);
        assert_eq!(simplified[1].x, 49.0);
        assert_eq!(simplified[1].y, 0.0);
    }
}
