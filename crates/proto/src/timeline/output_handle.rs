use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

const ID_BYTES_LIMIT: usize = 256;

/// A transcript output reference, kept as a string on the existing wire format.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputHandle {
    epoch: u64,
    offset: u64,
    id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidOutputHandle;

impl fmt::Display for InvalidOutputHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("the output handle is invalid")
    }
}

impl std::error::Error for InvalidOutputHandle {}

impl OutputHandle {
    pub fn new(
        epoch: u64,
        offset: u64,
        id: impl Into<String>,
    ) -> Result<Self, InvalidOutputHandle> {
        let id = id.into();
        if id.is_empty() || id.len() > ID_BYTES_LIMIT {
            return Err(InvalidOutputHandle);
        }
        Ok(Self { epoch, offset, id })
    }

    pub fn epoch(&self) -> u64 {
        self.epoch
    }
    /// Byte offset of the JSONL record, not a page into its output.
    pub fn offset(&self) -> u64 {
        self.offset
    }
    pub fn id(&self) -> &str {
        &self.id
    }
    pub fn set_epoch(&mut self, epoch: u64) {
        self.epoch = epoch;
    }
}

impl fmt::Display for OutputHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}:{}:{}", self.epoch, self.offset, self.id)
    }
}

impl FromStr for OutputHandle {
    type Err = InvalidOutputHandle;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let (epoch, rest) = value.split_once(':').ok_or(InvalidOutputHandle)?;
        let (offset, id) = rest.split_once(':').ok_or(InvalidOutputHandle)?;
        Self::new(
            epoch.parse().map_err(|_| InvalidOutputHandle)?,
            offset.parse().map_err(|_| InvalidOutputHandle)?,
            id,
        )
    }
}

impl Serialize for OutputHandle {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for OutputHandle {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?
            .parse()
            .map_err(serde::de::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn string_wire_encoding_is_unchanged_and_colons_belong_to_the_identifier() {
        let value = "7:19:tool:part";
        let handle: OutputHandle = value.parse().unwrap();
        assert_eq!(
            (handle.epoch(), handle.offset(), handle.id()),
            (7, 19, "tool:part")
        );
        assert_eq!(handle.to_string(), value);
        assert_eq!(
            postcard::to_allocvec(&handle).unwrap(),
            b"\x0e7:19:tool:part"
        );
        assert_eq!(
            postcard::to_allocvec(&handle).unwrap(),
            postcard::to_allocvec(value).unwrap()
        );
        assert_eq!(
            serde_json::to_string(&handle).unwrap(),
            serde_json::to_string(value).unwrap()
        );
        assert_eq!(
            postcard::from_bytes::<OutputHandle>(&postcard::to_allocvec(value).unwrap()).unwrap(),
            handle
        );
        assert_eq!(
            serde_json::from_str::<OutputHandle>(&serde_json::to_string(value).unwrap()).unwrap(),
            handle
        );
    }

    #[test]
    fn invalid_and_overflowing_components_are_rejected_once_at_the_boundary() {
        for value in [
            "",
            "7:tool",
            "7:0:",
            "-1:0:tool",
            "7:no:tool",
            "18446744073709551616:0:tool",
            "7:18446744073709551616:tool",
        ] {
            assert!(value.parse::<OutputHandle>().is_err(), "{value}");
        }
        assert!(OutputHandle::new(0, 0, "🦀".repeat(64)).is_ok());
        assert!(OutputHandle::new(0, 0, format!("{}x", "🦀".repeat(64))).is_err());
        assert!(OutputHandle::new(0, 0, "").is_err());
        assert!(serde_json::from_str::<OutputHandle>("\"7:0:\"").is_err());
        let maximum = OutputHandle::new(u64::MAX, u64::MAX, "tool").unwrap();
        assert_eq!(
            maximum.to_string().parse::<OutputHandle>().unwrap(),
            maximum
        );
    }
}
