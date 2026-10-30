//! Kitty graphics: the images programs send with the kitty graphics protocol, kept by
//! libghostty-vt in the terminal's image storage and carried by snapshots.

use std::ffi::c_void;
use std::ptr;
use std::slice;
use std::sync::Once;

use ghostty_vt_sys as ffi;

use crate::{Error, Terminal};

/// Image storage each screen of a terminal gets unless told otherwise, in bytes.
///
/// The same default on both ends keeps a client's mirror from evicting images the daemon
/// still places.
pub const KITTY_IMAGE_STORAGE_LIMIT: u64 = 64 << 20;

/// Pixel layout of a stored image. Stored images are always decoded and uncompressed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ImageFormat {
    /// 8-bit red, green, blue.
    Rgb,
    /// 8-bit red, green, blue and straight alpha.
    Rgba,
    /// 8-bit gray.
    Gray,
    /// 8-bit gray and straight alpha.
    GrayAlpha,
}

impl ImageFormat {
    fn from_raw(raw: ffi::GhosttyKittyImageFormat) -> Option<Self> {
        match raw {
            ffi::GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_RGB => Some(Self::Rgb),
            ffi::GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_RGBA => Some(Self::Rgba),
            ffi::GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_GRAY => Some(Self::Gray),
            ffi::GhosttyKittyImageFormat_GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA => {
                Some(Self::GrayAlpha)
            }
            _ => None,
        }
    }
}

/// An image in the active screen's storage.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KittyImage {
    /// The image id programs refer to it by.
    pub id: u32,
    pub width: u32,
    pub height: u32,
    pub format: ImageFormat,
    /// Changes whenever the pixels may have changed (resent, next animation frame).
    pub generation: u64,
    /// The pixels, or `None` while they are still on the way (restored from a snapshot
    /// whose pixel records have not arrived yet).
    pub pixels: Option<Vec<u8>>,
}

/// A placement in the active screen's storage, with where it is relative to the viewport.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct KittyPlacement {
    pub image_id: u32,
    /// 0 when the program gave none.
    pub placement_id: u32,
    /// Shown with Unicode placeholder cells instead of at a cell of its own.
    pub is_virtual: bool,
    pub z: i32,
    /// Cells covered.
    pub cols: u32,
    pub rows: u32,
    /// Size drawn, in the terminal's cell pixels.
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// Top-left cell relative to the viewport (the row is negative once its top scrolled
    /// above it); `None` when no part of it is in the viewport, or for virtual placements.
    pub viewport: Option<(i32, i32)>,
}

impl Terminal {
    /// Caps each screen's image storage at `bytes`; older images are evicted to fit. Zero
    /// turns the kitty graphics protocol off.
    ///
    /// # Errors
    ///
    /// Returns an error if libghostty-vt rejects the option.
    pub fn set_kitty_image_storage_limit(&mut self, bytes: u64) -> Result<(), Error> {
        // SAFETY: the handle is live; KITTY_IMAGE_STORAGE_LIMIT reads a `uint64_t *` before
        // returning.
        Error::check(unsafe {
            ffi::ghostty_terminal_set(
                self.as_raw(),
                ffi::GhosttyTerminalOption_GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
                ptr::from_ref(&bytes).cast(),
            )
        })
    }

    /// The image `id` on the active screen, with a copy of its pixels.
    ///
    /// # Examples
    ///
    /// ```
    /// # fn main() -> Result<(), ghostty_vt::Error> {
    /// let mut terminal = ghostty_vt::Terminal::new(20, 5)?;
    /// // A 1×1 RGBA image, transmitted and displayed.
    /// terminal.write(b"\x1b_Ga=T,f=32,s=1,v=1,i=7,q=2;/wAA/w==\x1b\\");
    /// let image = terminal.kitty_image(7).expect("stored");
    /// assert_eq!(image.pixels.as_deref(), Some(&[0xff, 0, 0, 0xff][..]));
    /// assert_eq!(terminal.kitty_placements().len(), 1);
    /// # Ok(())
    /// # }
    /// ```
    pub fn kitty_image(&self, id: u32) -> Option<KittyImage> {
        let graphics = self.kitty_graphics()?;
        // SAFETY: the storage handle is live until `self` is mutated, which `&self` rules out.
        let image = unsafe { ffi::ghostty_kitty_graphics_image(graphics, id) };
        if image.is_null() {
            return None;
        }
        let get = |data, out: *mut c_void| {
            // SAFETY: `image` is live as above and `out` points at the type documented for
            // `data`.
            let result = unsafe { ffi::ghostty_kitty_graphics_image_get(image, data, out) };
            result == ffi::GhosttyResult_GHOSTTY_SUCCESS
        };
        let (mut width, mut height, mut format, mut generation) = (0u32, 0u32, 0, 0u64);
        let complete = get(
            ffi::GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_WIDTH,
            (&raw mut width).cast(),
        ) && get(
            ffi::GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_HEIGHT,
            (&raw mut height).cast(),
        ) && get(
            ffi::GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_FORMAT,
            (&raw mut format).cast(),
        ) && get(
            ffi::GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_GENERATION,
            (&raw mut generation).cast(),
        );
        if !complete {
            return None;
        }
        let mut data: *const u8 = ptr::null();
        let mut len = 0usize;
        let pixels = (get(
            ffi::GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR,
            (&raw mut data).cast(),
        ) && get(
            ffi::GhosttyKittyGraphicsImageData_GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN,
            (&raw mut len).cast(),
        ) && !data.is_null())
        // SAFETY: DATA_PTR is valid for DATA_LEN bytes until the terminal is mutated.
        .then(|| unsafe { slice::from_raw_parts(data, len) }.to_vec());
        Some(KittyImage {
            id,
            width,
            height,
            format: ImageFormat::from_raw(format)?,
            generation,
            pixels,
        })
    }

    /// Every placement in the active screen's storage, including those off screen.
    pub fn kitty_placements(&self) -> Vec<KittyPlacement> {
        let Some(graphics) = self.kitty_graphics() else {
            return Vec::new();
        };
        let mut iter = ptr::null_mut();
        // SAFETY: `iter` is a valid out pointer; a null allocator selects the default one.
        if unsafe { ffi::ghostty_kitty_graphics_placement_iterator_new(ptr::null(), &mut iter) }
            != ffi::GhosttyResult_GHOSTTY_SUCCESS
        {
            return Vec::new();
        }
        let mut out = Vec::new();
        // SAFETY: the storage and terminal stay live and unmutated for this `&self` call; the
        // iterator is ours and freed below.
        unsafe {
            let filled = ffi::ghostty_kitty_graphics_get(
                graphics,
                ffi::GhosttyKittyGraphicsData_GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR,
                (&raw mut iter).cast(),
            ) == ffi::GhosttyResult_GHOSTTY_SUCCESS;
            while filled && ffi::ghostty_kitty_graphics_placement_next(iter) {
                if let Some(p) = placement(iter, graphics, self.as_raw()) {
                    out.push(p);
                }
            }
            ffi::ghostty_kitty_graphics_placement_iterator_free(iter);
        }
        out
    }

    /// The active screen's image storage, borrowed until the next mutation.
    fn kitty_graphics(&self) -> Option<ffi::GhosttyKittyGraphics> {
        let mut graphics: ffi::GhosttyKittyGraphics = ptr::null_mut();
        // SAFETY: KITTY_GRAPHICS writes a `GhosttyKittyGraphics`.
        let result = unsafe {
            ffi::ghostty_terminal_get(
                self.as_raw(),
                ffi::GhosttyTerminalData_GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
                (&raw mut graphics).cast(),
            )
        };
        (result == ffi::GhosttyResult_GHOSTTY_SUCCESS && !graphics.is_null()).then_some(graphics)
    }
}

/// Reads the iterator's current placement.
///
/// # Safety
///
/// `iter` must be positioned on a placement of `graphics`, which belongs to the live, unmutated
/// `terminal`.
unsafe fn placement(
    iter: ffi::GhosttyKittyGraphicsPlacementIterator,
    graphics: ffi::GhosttyKittyGraphics,
    terminal: ffi::GhosttyTerminal,
) -> Option<KittyPlacement> {
    let get = |data, out: *mut c_void| {
        // SAFETY: as the caller guarantees; `out` points at the type documented for `data`.
        let result = unsafe { ffi::ghostty_kitty_graphics_placement_get(iter, data, out) };
        result == ffi::GhosttyResult_GHOSTTY_SUCCESS
    };
    let (mut image_id, mut placement_id, mut is_virtual, mut z) = (0u32, 0u32, false, 0i32);
    let read = get(
        ffi::GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID,
        (&raw mut image_id).cast(),
    ) && get(
        ffi::GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID,
        (&raw mut placement_id).cast(),
    ) && get(
        ffi::GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL,
        (&raw mut is_virtual).cast(),
    ) && get(
        ffi::GhosttyKittyGraphicsPlacementData_GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z,
        (&raw mut z).cast(),
    );
    if !read {
        return None;
    }
    // SAFETY: as the caller guarantees.
    let image = unsafe { ffi::ghostty_kitty_graphics_image(graphics, image_id) };
    let mut info = ffi::GhosttyKittyGraphicsPlacementRenderInfo {
        size: size_of::<ffi::GhosttyKittyGraphicsPlacementRenderInfo>(),
        ..Default::default()
    };
    // SAFETY: as the caller guarantees; `info` is a sized out struct.
    let geometry = !image.is_null()
        && unsafe {
            ffi::ghostty_kitty_graphics_placement_render_info(iter, image, terminal, &mut info)
        } == ffi::GhosttyResult_GHOSTTY_SUCCESS;
    Some(KittyPlacement {
        image_id,
        placement_id,
        is_virtual,
        z,
        cols: if geometry { info.grid_cols } else { 0 },
        rows: if geometry { info.grid_rows } else { 0 },
        pixel_width: if geometry { info.pixel_width } else { 0 },
        pixel_height: if geometry { info.pixel_height } else { 0 },
        viewport: (geometry && info.viewport_visible)
            .then_some((info.viewport_col, info.viewport_row)),
    })
}

/// Installs the process-wide PNG decoder libghostty-vt needs to accept PNG images (`f=100`).
pub(crate) fn install_png_decoder() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let decode: ffi::GhosttySysDecodePngFn = Some(decode_png);
        // SAFETY: DECODE_PNG takes the function pointer itself as the value.
        let result = unsafe {
            ffi::ghostty_sys_set(
                ffi::GhosttySysOption_GHOSTTY_SYS_OPT_DECODE_PNG,
                decode.map_or(ptr::null(), |f| f as *const c_void),
            )
        };
        debug_assert_eq!(result, ffi::GhosttyResult_GHOSTTY_SUCCESS);
    });
}

unsafe extern "C" fn decode_png(
    _userdata: *mut c_void,
    allocator: *const ffi::GhosttyAllocator,
    data: *const u8,
    len: usize,
    out: *mut ffi::GhosttySysImage,
) -> bool {
    if data.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: libghostty-vt passes `len` readable bytes at `data` for the call.
    let png = unsafe { slice::from_raw_parts(data, len) };
    let Some((width, height, rgba)) = png_to_rgba(png) else {
        return false;
    };
    // SAFETY: the allocator is the one libghostty-vt passed for this buffer, which it frees.
    let buffer = unsafe { ffi::ghostty_alloc(allocator, rgba.len()) };
    if buffer.is_null() {
        return false;
    }
    // SAFETY: `buffer` holds `rgba.len()` bytes; `out` is the zeroed struct to fill in.
    unsafe {
        ptr::copy_nonoverlapping(rgba.as_ptr(), buffer, rgba.len());
        *out = ffi::GhosttySysImage {
            width,
            height,
            data: buffer,
            data_len: rgba.len(),
        };
    }
    true
}

/// Whether a PNG of `width` × `height` may be decoded: within libghostty-vt's 10000-pixel
/// side and, as RGBA, within the default image storage, so a few compressed bytes cannot ask
/// for gigabytes. The app's decoder applies the same rule, so both sides keep the same images.
fn png_fits(width: u32, height: u32) -> bool {
    width <= 10_000
        && height <= 10_000
        && u64::from(width) * u64::from(height) * 4 <= KITTY_IMAGE_STORAGE_LIMIT
}

/// Decodes a PNG to 8-bit straight-alpha RGBA.
fn png_to_rgba(png: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(png));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let (width, height) = reader.info().size();
    if !png_fits(width, height) {
        return None;
    }
    let mut buf = vec![0; reader.output_buffer_size()?];
    let frame = reader.next_frame(&mut buf).ok()?;
    buf.truncate(frame.buffer_size());
    let rgba = match frame.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf
            .as_chunks::<3>()
            .0
            .iter()
            .flat_map(|[r, g, b]| [*r, *g, *b, 0xff])
            .collect(),
        png::ColorType::GrayscaleAlpha => buf
            .as_chunks::<2>()
            .0
            .iter()
            .flat_map(|[g, a]| [*g, *g, *g, *a])
            .collect(),
        png::ColorType::Grayscale => buf.iter().flat_map(|&g| [g, g, g, 0xff]).collect(),
        png::ColorType::Indexed => return None,
    };
    Some((frame.width, frame.height, rgba))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png(width: u32, height: u32, color: png::ColorType, data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut encoder = png::Encoder::new(&mut out, width, height);
        encoder.set_color(color);
        encoder.set_depth(png::BitDepth::Eight);
        encoder
            .write_header()
            .and_then(|mut w| w.write_image_data(data))
            .unwrap();
        out
    }

    #[test]
    fn pngs_decode_to_rgba() {
        let rgb = png(2, 1, png::ColorType::Rgb, &[1, 2, 3, 4, 5, 6]);
        assert_eq!(
            png_to_rgba(&rgb),
            Some((2, 1, vec![1, 2, 3, 255, 4, 5, 6, 255]))
        );
        let gray = png(1, 1, png::ColorType::GrayscaleAlpha, &[9, 128]);
        assert_eq!(png_to_rgba(&gray), Some((1, 1, vec![9, 9, 9, 128])));
        assert_eq!(png_to_rgba(b"not a png"), None);
    }

    /// A tiny PNG whose header claims a huge grey image is refused before anything is
    /// allocated for it: as RGBA it would not fit the image storage anyway.
    #[test]
    fn oversized_pngs_are_refused() {
        let side = 5_000;
        let mut out = Vec::new();
        let mut encoder = png::Encoder::new(&mut out, side, side);
        encoder.set_color(png::ColorType::Grayscale);
        encoder.set_compression(png::Compression::Fast);
        encoder
            .write_header()
            .and_then(|mut w| w.write_image_data(&vec![0; (side * side) as usize]))
            .unwrap();
        assert!(out.len() < 1 << 20, "{}", out.len());
        assert_eq!(png_to_rgba(&out), None);
        assert!(png_fits(4_096, 4_096));
        assert!(!png_fits(10_001, 1));
    }

    #[test]
    fn png_images_are_stored_and_placed() -> Result<(), Error> {
        let mut terminal = Terminal::new(20, 6)?;
        terminal.resize(20, 6, (10, 20))?;
        let data = png(20, 40, png::ColorType::Rgba, &[200; 20 * 40 * 4]);
        let b64 = data_encoding::BASE64.encode(&data);
        terminal.write(format!("\x1b_Ga=T,f=100,i=3,q=2;{b64}\x1b\\").as_bytes());
        let image = terminal.kitty_image(3).expect("stored");
        assert_eq!(
            (image.width, image.height, image.format),
            (20, 40, ImageFormat::Rgba)
        );
        assert_eq!(image.pixels.map(|p| p.len()), Some(20 * 40 * 4));
        let placements = terminal.kitty_placements();
        assert_eq!(placements.len(), 1);
        let p = placements[0];
        assert_eq!((p.cols, p.rows, p.viewport), (2, 2, Some((0, 0))));
        // The cursor moved to the image's last row, past its right edge.
        assert_eq!((terminal.cursor().x, terminal.cursor().y), (2, 1));
        Ok(())
    }

    #[test]
    fn storage_limit_zero_turns_graphics_off() -> Result<(), Error> {
        let mut terminal = Terminal::new(20, 6)?;
        terminal.set_kitty_image_storage_limit(0)?;
        terminal.write(b"\x1b_Ga=T,f=32,s=1,v=1,i=7,q=2;/wAA/w==\x1b\\");
        assert_eq!(terminal.kitty_image(7), None);
        Ok(())
    }
}
