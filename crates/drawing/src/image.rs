//! PNG encoding of [`Rgba`] images and image header sniffing (format and size, no decoding).

use std::io::{self, Read, Seek, Write};

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
    sniff_reader(&mut io::Cursor::new(bytes))
}

/// [`sniff`] reading only the headers from `reader`, which starts at the image's first byte:
/// a file needs no more than its headers in memory. Give it a `BufReader`, since a JPEG's
/// headers are read segment by segment.
pub fn sniff_reader(reader: &mut (impl Read + Seek)) -> Option<(MediaType, u32, u32)> {
    let mut head = Vec::with_capacity(24);
    reader.by_ref().take(24).read_to_end(&mut head).ok()?;
    if head.starts_with(PNG_MAGIC) {
        // IHDR is always the first chunk.
        if head.get(12..16)? != b"IHDR" {
            return None;
        }
        let width = u32::from_be_bytes(head.get(16..20)?.try_into().ok()?);
        let height = u32::from_be_bytes(head.get(20..24)?.try_into().ok()?);
        return (width > 0 && height > 0).then_some((MediaType::Png, width, height));
    }
    if !head.starts_with(&[0xff, 0xd8]) {
        return None;
    }
    // Each step reads the ten bytes at the next marker: a marker with no room for them ends
    // the search.
    let mut at_marker = [0; 10];
    reader
        .seek_relative(2 - i64::try_from(head.len()).ok()?)
        .ok()?;
    loop {
        reader.read_exact(&mut at_marker).ok()?;
        if at_marker[0] != 0xff {
            return None;
        }
        let marker = at_marker[1];
        // Standalone markers (SOI, RSTn, TEM) carry no length.
        if marker == 0xd8 || (0xd0..=0xd7).contains(&marker) || marker == 0x01 {
            reader.seek_relative(2 - 10).ok()?;
            continue;
        }
        let segment_len = i64::from(u16::from_be_bytes([at_marker[2], at_marker[3]]));
        // SOF0..SOF15 except DHT (c4), JPG (c8), DAC (cc).
        if (0xc0..=0xcf).contains(&marker) && ![0xc4, 0xc8, 0xcc].contains(&marker) {
            let height = u32::from(u16::from_be_bytes([at_marker[5], at_marker[6]]));
            let width = u32::from(u16::from_be_bytes([at_marker[7], at_marker[8]]));
            return (width > 0 && height > 0).then_some((MediaType::Jpeg, width, height));
        }
        reader.seek_relative(2 + segment_len - 10).ok()?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jpeg_with_app_segments(segments: usize, width: u16, height: u16) -> Vec<u8> {
        let mut jpeg = vec![0xff, 0xd8];
        for _ in 0..segments {
            jpeg.extend_from_slice(&[0xff, 0xe1, 0xff, 0xff]);
            jpeg.extend(std::iter::repeat_n(0, 0xffff - 2));
        }
        jpeg.extend_from_slice(&[0xff, 0xc0, 0, 17, 8]);
        jpeg.extend_from_slice(&height.to_be_bytes());
        jpeg.extend_from_slice(&width.to_be_bytes());
        jpeg.extend_from_slice(&[3; 12]);
        jpeg
    }

    #[test]
    fn a_reader_sees_what_the_bytes_show() {
        let png = encode_png(&Rgba {
            width: 3,
            height: 2,
            data: vec![255; 24],
        });
        let jpeg = jpeg_with_app_segments(20, 640, 480);
        let truncated = &jpeg[..jpeg.len() - 15];
        for bytes in [&png[..], &jpeg, truncated, b"GIF89a", b"\xff\xd8\xff", b""] {
            let mut reader = io::BufReader::new(io::Cursor::new(bytes));
            assert_eq!(sniff_reader(&mut reader), sniff(bytes));
        }
        assert_eq!(sniff(&jpeg), Some((MediaType::Jpeg, 640, 480)));
        assert_eq!(sniff(truncated), None);
    }
}
