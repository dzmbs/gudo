//! Removing what an image says about where, when and on what it was taken.

const PNG_MAGIC: &[u8] = b"\x89PNG\r\n\x1a\n";

/// PNG chunks that draw the image: the critical ones, transparency, colour, pixel size,
/// background and APNG frames. Text, `eXIf`, `tIME` and private chunks are dropped.
const PNG_KEPT: &[&[u8; 4]] = &[
    b"IHDR", b"PLTE", b"IDAT", b"IEND", b"tRNS", b"gAMA", b"cHRM", b"sRGB", b"iCCP", b"sBIT",
    b"cICP", b"mDCv", b"cLLi", b"pHYs", b"bKGD", b"acTL", b"fcTL", b"fdAT",
];

const EXIF_HEADER: &[u8] = b"Exif\0\0";
const ORIENTATION_TAG: u16 = 0x0112;

/// `image` without its metadata: EXIF (GPS position, camera, time), XMP, IPTC, comments and
/// PNG text chunks, and anything after the image's end. A JPEG keeps its EXIF orientation,
/// rewritten as the only EXIF field, so a photo is not shown on its side. `None` when
/// `image` is not a PNG or JPEG whose structure can be walked.
///
/// # Examples
///
/// ```
/// use drawing::{Rgba, encode_png, strip_metadata};
///
/// let png = encode_png(&Rgba { width: 1, height: 1, data: vec![255; 4] });
/// assert_eq!(strip_metadata(&png).as_deref(), Some(&png[..]));
/// assert_eq!(strip_metadata(b"GIF89a"), None);
/// ```
pub fn strip_metadata(image: &[u8]) -> Option<Vec<u8>> {
    if image.starts_with(PNG_MAGIC) {
        strip_png(image)
    } else if image.starts_with(&[0xff, 0xd8]) {
        strip_jpeg(image)
    } else {
        None
    }
}

fn strip_png(image: &[u8]) -> Option<Vec<u8>> {
    let mut stripped = PNG_MAGIC.to_vec();
    let mut orientation = None;
    let mut exif_at = None;
    let mut at = PNG_MAGIC.len();
    while at < image.len() {
        let length =
            usize::try_from(u32::from_be_bytes(image.get(at..at + 4)?.try_into().ok()?)).ok()?;
        let kind: &[u8; 4] = image.get(at + 4..at + 8)?.try_into().ok()?;
        let end = at.checked_add(12)?.checked_add(length)?;
        let chunk = image.get(at..end)?;
        if kind == b"eXIf" && orientation.is_none() {
            orientation = exif_orientation(&chunk[8..8 + length]);
        }
        if (kind == b"IDAT" || kind == b"IEND") && exif_at.is_none() {
            exif_at = Some(stripped.len());
        }
        if PNG_KEPT.contains(&kind) {
            stripped.extend_from_slice(chunk);
        }
        if kind == b"IEND" {
            break;
        }
        at = end;
    }
    if let Some(orientation) = orientation {
        let mut chunk = Vec::new();
        crate::image::chunk(&mut chunk, b"eXIf", &orientation_tiff(orientation));
        let at = exif_at.unwrap_or(stripped.len());
        stripped.splice(at..at, chunk);
    }
    Some(stripped)
}

fn strip_jpeg(image: &[u8]) -> Option<Vec<u8>> {
    let mut stripped = Vec::with_capacity(image.len());
    stripped.extend_from_slice(&[0xff, 0xd8]);
    let mut orientation = None;
    // Where the rebuilt EXIF goes: after the JFIF segment that must come first.
    let mut exif_at = stripped.len();
    let mut at = 2;
    loop {
        if *image.get(at)? != 0xff {
            return None;
        }
        while image.get(at + 1) == Some(&0xff) {
            at += 1;
        }
        let Some(&marker) = image.get(at + 1) else {
            break;
        };
        match marker {
            0xd9 => {
                stripped.extend_from_slice(&[0xff, 0xd9]);
                break;
            }
            0x01 | 0xd0..=0xd7 => {
                stripped.extend_from_slice(&[0xff, marker]);
                at += 2;
                continue;
            }
            _ => {}
        }
        let length = usize::from(u16::from_be_bytes([
            *image.get(at + 2)?,
            *image.get(at + 3)?,
        ]));
        if length < 2 {
            return None;
        }
        let segment = image.get(at..at + 2 + length)?;
        let payload = &segment[4..];
        match marker {
            0xe0 if payload.starts_with(b"JFIF\0") || payload.starts_with(b"JFXX\0") => {
                stripped.extend_from_slice(segment);
                if exif_at == stripped.len() - segment.len() {
                    exif_at = stripped.len();
                }
            }
            0xe1 => {
                if orientation.is_none() {
                    orientation = payload.strip_prefix(EXIF_HEADER).and_then(exif_orientation);
                }
            }
            0xe2 if payload.starts_with(b"ICC_PROFILE\0") => stripped.extend_from_slice(segment),
            0xee if payload.starts_with(b"Adobe") => stripped.extend_from_slice(segment),
            0xe0..=0xef | 0xfe => {}
            0xda => {
                let scan_end = entropy_end(image, at + 2 + length);
                stripped.extend_from_slice(&image[at..scan_end]);
                at = scan_end;
                if at >= image.len() {
                    break;
                }
                continue;
            }
            _ => stripped.extend_from_slice(segment),
        }
        at += 2 + length;
    }
    if let Some(orientation) = orientation {
        let exif = orientation_exif(orientation);
        stripped.splice(exif_at..exif_at, exif);
    }
    Some(stripped)
}

/// Where the entropy-coded data starting at `from` ends: at the first marker that is neither
/// a stuffed `FF 00` nor a restart marker, or at the end of `image`.
fn entropy_end(image: &[u8], from: usize) -> usize {
    let mut at = from;
    while at + 1 < image.len() {
        if image[at] == 0xff {
            let next = image[at + 1];
            if next != 0x00 && !(0xd0..=0xd7).contains(&next) && next != 0xff {
                return at;
            }
        }
        at += 1;
    }
    image.len()
}

/// The orientation (2 to 8) in a TIFF structure's first IFD; 1, the default, counts as none.
fn exif_orientation(tiff: &[u8]) -> Option<u16> {
    let big_endian = match tiff.get(..4)? {
        b"MM\0*" => true,
        b"II*\0" => false,
        _ => return None,
    };
    let read_u16 = |at: usize| -> Option<u16> {
        let bytes: [u8; 2] = tiff.get(at..at + 2)?.try_into().ok()?;
        Some(if big_endian {
            u16::from_be_bytes(bytes)
        } else {
            u16::from_le_bytes(bytes)
        })
    };
    let read_u32 = |at: usize| -> Option<u32> {
        let bytes: [u8; 4] = tiff.get(at..at + 4)?.try_into().ok()?;
        Some(if big_endian {
            u32::from_be_bytes(bytes)
        } else {
            u32::from_le_bytes(bytes)
        })
    };
    let ifd = usize::try_from(read_u32(4)?).ok()?;
    let entries = usize::from(read_u16(ifd)?);
    (0..entries).find_map(|index| {
        let entry = ifd + 2 + index * 12;
        let is_short = read_u16(entry + 2)? == 3;
        (read_u16(entry)? == ORIENTATION_TAG && is_short)
            .then(|| read_u16(entry + 8))
            .flatten()
            .filter(|orientation| (2..=8).contains(orientation))
    })
}

/// An APP1 segment whose EXIF holds only `orientation`.
fn orientation_exif(orientation: u16) -> Vec<u8> {
    let payload = [EXIF_HEADER, &orientation_tiff(orientation)].concat();
    let mut segment = vec![0xff, 0xe1];
    segment.extend_from_slice(&u16::try_from(payload.len() + 2).unwrap_or(0).to_be_bytes());
    segment.extend_from_slice(&payload);
    segment
}

/// A TIFF structure whose only field is `orientation`.
fn orientation_tiff(orientation: u16) -> Vec<u8> {
    let mut payload = b"MM\0*".to_vec();
    payload.extend_from_slice(&8u32.to_be_bytes());
    payload.extend_from_slice(&1u16.to_be_bytes());
    payload.extend_from_slice(&ORIENTATION_TAG.to_be_bytes());
    payload.extend_from_slice(&3u16.to_be_bytes());
    payload.extend_from_slice(&1u32.to_be_bytes());
    payload.extend_from_slice(&orientation.to_be_bytes());
    payload.extend_from_slice(&[0, 0]);
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Rgba, encode_png, sniff};

    fn segment(marker: u8, payload: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0xff, marker];
        bytes.extend_from_slice(&u16::try_from(payload.len() + 2).unwrap().to_be_bytes());
        bytes.extend_from_slice(payload);
        bytes
    }

    fn little_endian_exif(orientation: u16, secret: &[u8]) -> Vec<u8> {
        let mut exif = EXIF_HEADER.to_vec();
        exif.extend_from_slice(b"II*\0");
        exif.extend_from_slice(&8u32.to_le_bytes());
        exif.extend_from_slice(&2u16.to_le_bytes());
        // GPS IFD pointer, then the orientation.
        exif.extend_from_slice(&0x8825u16.to_le_bytes());
        exif.extend_from_slice(&4u16.to_le_bytes());
        exif.extend_from_slice(&1u32.to_le_bytes());
        exif.extend_from_slice(&38u32.to_le_bytes());
        exif.extend_from_slice(&ORIENTATION_TAG.to_le_bytes());
        exif.extend_from_slice(&3u16.to_le_bytes());
        exif.extend_from_slice(&1u32.to_le_bytes());
        exif.extend_from_slice(&orientation.to_le_bytes());
        exif.extend_from_slice(&[0, 0]);
        exif.extend_from_slice(&0u32.to_le_bytes());
        exif.extend_from_slice(secret);
        exif
    }

    const SECRET: &[u8] = b"GPS 48.8584 N 2.2945 E";

    fn photo(orientation: u16) -> (Vec<u8>, Vec<u8>) {
        let jfif = segment(0xe0, b"JFIF\0\x01\x02\0\0\x01\0\x01\0\0");
        let tables = [
            segment(0xdb, &[0; 65]),
            segment(0xc0, &[8, 0, 2, 0, 3, 1, 1, 0x11, 0]),
            segment(0xc4, &[0; 20]),
        ]
        .concat();
        let scan = [
            segment(0xda, &[1, 1, 0, 0, 63, 0]),
            vec![0x12, 0xff, 0x00, 0x34, 0xff, 0xd0, 0x56, 0xff, 0xff, 0xd9],
        ]
        .concat();
        let original = [
            vec![0xff, 0xd8],
            jfif.clone(),
            segment(0xe1, &little_endian_exif(orientation, SECRET)),
            segment(
                0xe1,
                &[b"http://ns.adobe.com/xap/1.0/\0".as_slice(), SECRET].concat(),
            ),
            segment(0xed, &[b"Photoshop 3.0\0".as_slice(), SECRET].concat()),
            segment(0xe2, &[b"MPF\0".as_slice(), SECRET].concat()),
            segment(0xe2, b"ICC_PROFILE\0\x01\x01profile"),
            segment(0xfe, SECRET),
            tables.clone(),
            scan.clone(),
            [b"\xff\xd8\xff\xe1\0\x10Exif\0\0".as_slice(), SECRET].concat(),
        ]
        .concat();
        let mut expected = [vec![0xff, 0xd8], jfif].concat();
        if (2..=8).contains(&orientation) {
            expected.extend_from_slice(&orientation_exif(orientation));
        }
        expected.extend_from_slice(&segment(0xe2, b"ICC_PROFILE\0\x01\x01profile"));
        expected.extend_from_slice(&tables);
        expected.extend_from_slice(&scan);
        (original, expected)
    }

    #[test]
    fn a_photo_keeps_its_pixels_and_orientation_and_nothing_else() {
        let (original, expected) = photo(6);
        let stripped = strip_metadata(&original).unwrap();
        assert_eq!(stripped, expected);
        assert!(
            !stripped
                .windows(SECRET.len())
                .any(|window| window == SECRET)
        );
        let exif = &stripped[stripped.windows(6).position(|w| w == EXIF_HEADER).unwrap() + 6..];
        assert_eq!(exif_orientation(exif), Some(6));
        assert_eq!(sniff(&stripped), sniff(&original));
        assert_eq!(strip_metadata(&stripped).unwrap(), stripped);
    }

    #[test]
    fn an_upright_photo_gets_no_exif_at_all() {
        let (original, expected) = photo(1);
        let stripped = strip_metadata(&original).unwrap();
        assert_eq!(stripped, expected);
        assert!(!stripped.windows(4).any(|window| window == b"Exif"));
    }

    #[test]
    fn png_text_and_exif_chunks_are_dropped() {
        let png = encode_png(&Rgba {
            width: 2,
            height: 2,
            data: vec![9; 16],
        });
        let iend = png.len() - 12;
        let mut tagged = png[..iend].to_vec();
        for kind in [b"tEXt", b"iTXt", b"zTXt", b"eXIf", b"tIME", b"prVt"] {
            tagged.extend_from_slice(&u32::try_from(SECRET.len()).unwrap().to_be_bytes());
            tagged.extend_from_slice(kind);
            tagged.extend_from_slice(SECRET);
            tagged.extend_from_slice(&[0; 4]);
        }
        tagged.extend_from_slice(&png[iend..]);
        tagged.extend_from_slice(SECRET);
        assert_eq!(strip_metadata(&tagged).unwrap(), png);
    }

    #[test]
    fn a_png_keeps_only_its_orientation_before_the_pixels() {
        let png = encode_png(&Rgba {
            width: 2,
            height: 1,
            data: vec![7; 8],
        });
        let idat = 8 + 25;
        let exif = &little_endian_exif(8, SECRET)[EXIF_HEADER.len()..];
        let mut tagged = png[..idat].to_vec();
        crate::image::chunk(&mut tagged, b"eXIf", exif);
        tagged.extend_from_slice(&png[idat..]);
        let stripped = strip_metadata(&tagged).unwrap();
        let mut expected = png[..idat].to_vec();
        crate::image::chunk(&mut expected, b"eXIf", &orientation_tiff(8));
        expected.extend_from_slice(&png[idat..]);
        assert_eq!(stripped, expected);
        assert_eq!(strip_metadata(&stripped).unwrap(), stripped);
    }

    #[test]
    fn broken_structures_are_refused() {
        let (photo, _) = photo(6);
        assert_eq!(strip_metadata(&photo[..10]), None);
        assert_eq!(strip_metadata(&[0xff, 0xd8, 0x00, 0x01]), None);
        assert_eq!(strip_metadata(&[0xff, 0xd8, 0xff, 0xe1, 0x00, 0x01]), None);
        let png = encode_png(&Rgba {
            width: 1,
            height: 1,
            data: vec![0; 4],
        });
        assert_eq!(strip_metadata(&png[..png.len() - 3]), None);
        let mut huge = PNG_MAGIC.to_vec();
        huge.extend_from_slice(&[0xff, 0xff, 0xff, 0xff]);
        huge.extend_from_slice(b"IDAT");
        assert_eq!(strip_metadata(&huge), None);
    }

    #[test]
    fn hostile_exif_offsets_read_nothing() {
        assert_eq!(exif_orientation(b"MM\0*\xff\xff\xff\xff"), None);
        assert_eq!(exif_orientation(b"II*\0\x08\0\0\0\xff\xff"), None);
        assert_eq!(exif_orientation(b"XX"), None);
    }
}
