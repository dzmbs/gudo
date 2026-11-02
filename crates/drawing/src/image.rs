//! PNG encoding of [`Rgba`] images and image header sniffing (format and size, no decoding).

use std::io::Write;

use proto::MediaType;

use crate::raster::Rgba;

const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";

/// Encodes an RGBA image as PNG (8-bit RGBA, filter 0, zlib level 6).
pub fn encode_png(image: &Rgba) -> Vec<u8> {
    let (width, height) = (image.width as usize, image.height as usize);
    let mut scanlines = Vec::with_capacity((width * 4 + 1) * height);
    for row in image.data.chunks(width * 4).take(height) {
        scanlines.push(0);
        scanlines.extend_from_slice(row);
    }
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::new(6));
    let _ = encoder.write_all(&scanlines);
    let idat = encoder.finish().unwrap_or_default();
    let mut out = PNG_MAGIC.to_vec();
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&image.width.to_be_bytes());
    ihdr.extend_from_slice(&image.height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &idat);
    chunk(&mut out, b"IEND", &[]);
    out
}

fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut crc = flate2::Crc::new();
    crc.update(kind);
    crc.update(data);
    out.extend_from_slice(&crc.sum().to_be_bytes());
}

/// Format and pixel size of a PNG or JPEG, read from its header; `None` for anything else.
///
/// # Examples
///
/// ```
/// use drawing::{Rgba, encode_png, sniff};
///
/// let png = encode_png(&Rgba { width: 3, height: 2, data: vec![255; 24] });
/// assert_eq!(sniff(&png), Some((proto::MediaType::Png, 3, 2)));
/// assert_eq!(sniff(b"GIF89a"), None);
/// ```
pub fn sniff(bytes: &[u8]) -> Option<(MediaType, u32, u32)> {
    if bytes.starts_with(PNG_MAGIC) {
        // IHDR is always the first chunk.
        if bytes.get(12..16)? != b"IHDR" {
            return None;
        }
        let width = u32::from_be_bytes(bytes.get(16..20)?.try_into().ok()?);
        let height = u32::from_be_bytes(bytes.get(20..24)?.try_into().ok()?);
        return (width > 0 && height > 0).then_some((MediaType::Png, width, height));
    }
    if bytes.starts_with(&[0xff, 0xd8]) {
        let mut offset = 2;
        while offset + 9 < bytes.len() {
            if bytes[offset] != 0xff {
                return None;
            }
            let marker = bytes[offset + 1];
            // Standalone markers (SOI, RSTn, TEM) carry no length.
            if marker == 0xd8 || (0xd0..=0xd7).contains(&marker) || marker == 0x01 {
                offset += 2;
                continue;
            }
            let segment_len =
                usize::from(u16::from_be_bytes([bytes[offset + 2], bytes[offset + 3]]));
            // SOF0..SOF15 except DHT (c4), JPG (c8), DAC (cc).
            if (0xc0..=0xcf).contains(&marker) && ![0xc4, 0xc8, 0xcc].contains(&marker) {
                let height = u32::from(u16::from_be_bytes([bytes[offset + 5], bytes[offset + 6]]));
                let width = u32::from(u16::from_be_bytes([bytes[offset + 7], bytes[offset + 8]]));
                return (width > 0 && height > 0).then_some((MediaType::Jpeg, width, height));
            }
            offset += 2 + segment_len;
        }
    }
    None
}
