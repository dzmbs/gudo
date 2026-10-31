//! Kitty graphics that ask for far more memory than they send. Peak memory is the process's,
//! so this binary holds one test.

use std::io::Write;

use ghostty_vt::{KITTY_IMAGE_STORAGE_LIMIT, Terminal};

/// Peak resident memory of this process, in bytes.
fn peak_rss() -> u64 {
    // SAFETY: getrusage fills the zeroed struct it is given.
    let usage = unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut usage);
        usage
    };
    let max = u64::try_from(usage.ru_maxrss).unwrap_or(0);
    // Bytes on macOS, KiB on Linux.
    if cfg!(target_os = "macos") {
        max
    } else {
        max * 1024
    }
}

/// How much the process's peak memory grew while `attack` ran. Freed large blocks can stay
/// resident, so each attack is measured on its own.
fn peak_growth(attack: impl FnOnce()) -> u64 {
    let before = peak_rss();
    attack();
    peak_rss().saturating_sub(before)
}

/// `len` zero bytes, zlib-compressed: about a thousandth of `len`.
fn zlib_zeros(len: usize) -> Vec<u8> {
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
    let chunk = vec![0; 1 << 20];
    for start in (0..len).step_by(chunk.len()) {
        encoder
            .write_all(&chunk[..chunk.len().min(len - start)])
            .unwrap();
    }
    encoder.finish().unwrap()
}

/// Sends `data` as a chunked direct transmission with control keys `keys`.
fn transmit(term: &mut Terminal, keys: &str, data: &[u8]) {
    let encoded = data_encoding::BASE64.encode(data);
    let chunks: Vec<_> = encoded.as_bytes().chunks(4096).collect();
    for (i, chunk) in chunks.iter().enumerate() {
        let more = u8::from(i + 1 < chunks.len());
        let keys = if i == 0 {
            format!("{keys},m={more}")
        } else {
            format!("m={more}")
        };
        term.write(format!("\x1b_G{keys};").as_bytes());
        term.write(chunk);
        term.write(b"\x1b\\");
    }
}

/// A transmission may never hold more than the image storage keeps: a few hundred KiB of
/// zlib, or a long run of chunks, cannot make the terminal allocate hundreds of MiB for an
/// image it will refuse anyway.
#[test]
#[ignore = "libghostty-vt bounds a load by its own 400 MB, not by the image storage"]
fn transmissions_stay_within_the_image_storage() {
    let mut term = Terminal::new(80, 24).unwrap();
    term.set_kitty_image_storage_limit(KITTY_IMAGE_STORAGE_LIMIT)
        .unwrap();
    let bound = 2 * KITTY_IMAGE_STORAGE_LIMIT;

    let bomb = zlib_zeros(10_000 * 10_000 * 4);
    assert!(bomb.len() < 1 << 20, "{}", bomb.len());
    let attacks = [
        "a=t,f=32,s=10000,v=10000,o=z",
        "a=t,f=32,s=1,v=1,o=z",
        "a=t,f=32,o=z",
        "a=t,f=100,o=z",
    ];
    for (id, keys) in (1..).zip(attacks) {
        let grew = peak_growth(|| transmit(&mut term, &format!("{keys},i={id},q=2"), &bomb));
        assert!(grew < bound, "{keys}: peak grew by {} MiB", grew >> 20);
    }

    // Uncompressed chunks that never end, written a chunk at a time.
    let grew = peak_growth(|| {
        let chunk = data_encoding::BASE64.encode(&[0; 3 << 10]);
        term.write(format!("\x1b_Ga=t,f=32,s=1,v=1,i=5,q=2,m=1;{chunk}\x1b\\").as_bytes());
        for _ in 0..(300 << 20) / (3 << 10) {
            term.write(format!("\x1b_Gm=1;{chunk}\x1b\\").as_bytes());
        }
        term.write(b"\x1b_Gm=0;\x1b\\");
    });
    assert!(grew < bound, "chunks: peak grew by {} MiB", grew >> 20);
    for id in 1..=5 {
        assert_eq!(term.kitty_image(id), None);
    }

    // Real images past the storage evict the oldest.
    let image = zlib_zeros(4 << 20);
    let grew = peak_growth(|| {
        for id in 10..60 {
            let keys = format!("a=t,f=32,s=1024,v=1024,o=z,i={id},q=2");
            transmit(&mut term, &keys, &image);
        }
    });
    assert!(grew < bound, "images: peak grew by {} MiB", grew >> 20);
    assert!(term.kitty_image(59).is_some());
    assert_eq!(term.kitty_image(10), None);
}
