use std::fmt;

use ghostty_vt_sys as ffi;

/// A failure reported by libghostty-vt.
///
/// Each variant mirrors one `GhosttyResult` code. The C API reuses codes across operations, so
/// the meaning of a variant depends on the call; each fallible method documents which variants
/// it returns and why.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum Error {
    /// An allocation failed.
    OutOfMemory,
    /// An argument, the call order, or the input data was invalid.
    InvalidValue,
    /// A buffer was too small.
    OutOfSpace,
    /// The requested value is not available.
    NoValue,
    /// A reader or writer callback failed.
    Io,
    /// Input exceeded a configured limit.
    LimitExceeded,
    /// A safety check rejected the operation.
    Rejected,
    /// The linked libghostty-vt does not know the requested option or data key.
    Unsupported,
    /// A result code this binding does not know, from a newer libghostty-vt.
    Unknown(i32),
}

impl Error {
    /// Maps a raw result to `Ok(())` on success or the matching error otherwise.
    pub(crate) fn check(code: ffi::GhosttyResult) -> Result<(), Self> {
        Err(match code {
            ffi::GhosttyResult_GHOSTTY_SUCCESS => return Ok(()),
            ffi::GhosttyResult_GHOSTTY_OUT_OF_MEMORY => Self::OutOfMemory,
            ffi::GhosttyResult_GHOSTTY_INVALID_VALUE => Self::InvalidValue,
            ffi::GhosttyResult_GHOSTTY_OUT_OF_SPACE => Self::OutOfSpace,
            ffi::GhosttyResult_GHOSTTY_NO_VALUE => Self::NoValue,
            ffi::GhosttyResult_GHOSTTY_IO_ERROR => Self::Io,
            ffi::GhosttyResult_GHOSTTY_LIMIT_EXCEEDED => Self::LimitExceeded,
            ffi::GhosttyResult_GHOSTTY_REJECTED => Self::Rejected,
            ffi::GhosttyResult_GHOSTTY_UNSUPPORTED => Self::Unsupported,
            other => Self::Unknown(other),
        })
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OutOfMemory => f.write_str("libghostty-vt ran out of memory"),
            Self::InvalidValue => f.write_str("libghostty-vt rejected an invalid value"),
            Self::OutOfSpace => f.write_str("libghostty-vt output buffer too small"),
            Self::NoValue => f.write_str("libghostty-vt value not available"),
            Self::Io => f.write_str("libghostty-vt reader or writer failed"),
            Self::LimitExceeded => f.write_str("libghostty-vt limit exceeded"),
            Self::Rejected => f.write_str("libghostty-vt safety check rejected the operation"),
            Self::Unsupported => f.write_str("libghostty-vt does not support this option"),
            Self::Unknown(code) => write!(f, "libghostty-vt returned unknown result {code}"),
        }
    }
}

impl std::error::Error for Error {}
