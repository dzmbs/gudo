//! A byte payload that crosses the boundary in one copy.
//!
//! UniFFI already maps `Vec<u8>` to Swift `Data`, but its Rust converter writes and reads
//! the bytes one at a time (it is the generic `Vec<T>` converter): about 3 ns per byte,
//! 190 µs for a 64 KiB `PaneBytes` event. [`Bytes`] declares the same wire type (a
//! sequence of `u8`, so Swift still sees `Data`) with a bulk `memcpy` converter.

use uniffi::{FfiConverter, MetadataBuffer, metadata::codes};

/// Bytes as Swift `Data`, copied in bulk.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Bytes(pub Vec<u8>);

impl From<Vec<u8>> for Bytes {
    fn from(v: Vec<u8>) -> Self {
        Self(v)
    }
}

impl std::ops::Deref for Bytes {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        &self.0
    }
}

impl From<Bytes> for Vec<u8> {
    fn from(b: Bytes) -> Self {
        b.0
    }
}

// SAFETY: the wire format is UniFFI's own for `Vec<u8>` (big-endian i32 length, then the
// bytes), which is what `TYPE_ID_META` tells the bindings to expect.
unsafe impl FfiConverter<crate::UniFfiTag> for Bytes {
    uniffi::ffi_converter_rust_buffer_lift_and_lower!(crate::UniFfiTag);

    fn write(obj: Self, buf: &mut Vec<u8>) {
        let len = i32::try_from(obj.0.len()).expect("payloads stay below 2 GiB");
        buf.reserve(4 + obj.0.len());
        buf.extend_from_slice(&len.to_be_bytes());
        buf.extend_from_slice(&obj.0);
    }

    fn try_read(buf: &mut &[u8]) -> uniffi::Result<Self> {
        let Some((len, rest)) = buf.split_first_chunk::<4>() else {
            uniffi::deps::anyhow::bail!("bytes: missing length");
        };
        let len = usize::try_from(i32::from_be_bytes(*len))?;
        let Some((data, rest)) = rest.split_at_checked(len) else {
            uniffi::deps::anyhow::bail!("bytes: {len} bytes announced, {} left", rest.len());
        };
        *buf = rest;
        Ok(Self(data.to_vec()))
    }

    const TYPE_ID_META: MetadataBuffer =
        MetadataBuffer::from_code(codes::TYPE_VEC).concat_value(codes::TYPE_U8);
}

uniffi::derive_ffi_traits!(local Bytes);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_like_vec_u8() {
        let mut ours = Vec::new();
        <Bytes as FfiConverter<crate::UniFfiTag>>::write(Bytes(b"hello".to_vec()), &mut ours);
        let mut theirs = Vec::new();
        <Vec<u8> as uniffi::Lower<crate::UniFfiTag>>::write(b"hello".to_vec(), &mut theirs);
        assert_eq!(ours, theirs);
        let mut slice = ours.as_slice();
        let back = <Bytes as FfiConverter<crate::UniFfiTag>>::try_read(&mut slice).unwrap();
        assert_eq!(back.0, b"hello");
        assert!(slice.is_empty());
        let mut short: &[u8] = &[0, 0, 0, 9, 1];
        assert!(<Bytes as FfiConverter<crate::UniFfiTag>>::try_read(&mut short).is_err());
    }
}
