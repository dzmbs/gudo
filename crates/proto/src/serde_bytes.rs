//! `#[serde(with = "crate::serde_bytes")]` for `Vec<u8>` fields.
//!
//! postcard writes a byte string and a `u8` sequence identically (varint length, then raw
//! bytes), so this does not change the wire. It only avoids serde's per-element path, which
//! matters for multi-kilobyte `Bytes` and `Snapshot` payloads.

use std::fmt;

use serde::de::{self, Deserializer, SeqAccess, Visitor};
use serde::ser::Serializer;

pub(crate) fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_bytes(bytes)
}

pub(crate) fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
    deserializer.deserialize_byte_buf(ByteBufVisitor)
}

struct ByteBufVisitor;

impl<'de> Visitor<'de> for ByteBufVisitor {
    type Value = Vec<u8>;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a byte string")
    }

    fn visit_bytes<E: de::Error>(self, bytes: &[u8]) -> Result<Vec<u8>, E> {
        Ok(bytes.to_vec())
    }

    fn visit_byte_buf<E: de::Error>(self, bytes: Vec<u8>) -> Result<Vec<u8>, E> {
        Ok(bytes)
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Vec<u8>, A::Error> {
        let mut bytes = Vec::with_capacity(seq.size_hint().unwrap_or(0).min(4096));
        while let Some(byte) = seq.next_element()? {
            bytes.push(byte);
        }
        Ok(bytes)
    }
}
