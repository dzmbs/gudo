//! This build and machine, as [`proto::DaemonInfo`] (sent to clients before `Welcome`, and
//! printed by `gudo-hostd build-info --json` so a new build can be checked before it
//! replaces a running one).
//!
//! The build id and time come from the release tooling (`cargo xtask build-hostd-linux` sets
//! `GUDO_BUILD_ID` and `GUDO_BUILD_UNIX` at compile time); other builds report `dev` and 0.

use proto::{DaemonFeatures, DaemonInfo};

/// The build id baked in at compile time, or `dev`.
pub const BUILD_ID: &str = match option_env!("GUDO_BUILD_ID") {
    Some(id) => id,
    None => "dev",
};

/// When the build's source was made (Unix seconds), or 0 for `dev` builds.
pub fn built_unix() -> u64 {
    option_env!("GUDO_BUILD_UNIX")
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

/// This build and machine. `features` are what the running daemon offers (a build checked
/// with `build-info` reports none).
pub fn build_info(features: DaemonFeatures) -> DaemonInfo {
    DaemonInfo {
        version: env!("CARGO_PKG_VERSION").to_owned(),
        build: BUILD_ID.to_owned(),
        built_unix: built_unix(),
        protocol: proto::PROTOCOL_LEVEL,
        min_client_protocol: proto::MIN_CLIENT_PROTOCOL,
        features,
        hostname: hostname(),
        os: std::env::consts::OS.to_owned(),
        os_name: os_name(),
        arch: std::env::consts::ARCH.to_owned(),
    }
}

/// The machine's host name (`gethostname`), as the system has it: possibly with a domain.
pub fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: the buffer is valid for its length; gethostname writes at most that many bytes.
    let rc = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) };
    if rc != 0 {
        return String::new();
    }
    let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..len]).trim().to_owned()
}

/// The operating system in words: `PRETTY_NAME` from os-release on Linux, "macOS <version>"
/// on a Mac, else empty.
fn os_name() -> String {
    if cfg!(target_os = "macos") {
        let plist = std::fs::read_to_string("/System/Library/CoreServices/SystemVersion.plist")
            .unwrap_or_default();
        return plist_string(&plist, "ProductVersion")
            .map_or_else(|| "macOS".to_owned(), |v| format!("macOS {v}"));
    }
    ["/etc/os-release", "/usr/lib/os-release"]
        .iter()
        .find_map(|path| std::fs::read_to_string(path).ok())
        .and_then(|text| os_release_name(&text))
        .unwrap_or_default()
}

/// `PRETTY_NAME` (else `NAME`) from os-release text, unquoted.
fn os_release_name(text: &str) -> Option<String> {
    let value = |key: &str| {
        text.lines().find_map(|line| {
            let rest = line.trim().strip_prefix(key)?.strip_prefix('=')?;
            let v = rest.trim().trim_matches(|c| c == '"' || c == '\'');
            (!v.is_empty()).then(|| v.to_owned())
        })
    };
    value("PRETTY_NAME").or_else(|| value("NAME"))
}

/// The `<string>` after `<key>name</key>` in a property list.
fn plist_string(plist: &str, name: &str) -> Option<String> {
    let after = plist.split_once(&format!("<key>{name}</key>"))?.1;
    let start = after.find("<string>")? + "<string>".len();
    let end = after[start..].find("</string>")? + start;
    Some(after[start..end].trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn os_release_pretty_name_wins() {
        let text = "NAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\n";
        assert_eq!(os_release_name(text).as_deref(), Some("Ubuntu 24.04.1 LTS"));
        assert_eq!(
            os_release_name("NAME=Alpine Linux\n").as_deref(),
            Some("Alpine Linux")
        );
        assert_eq!(os_release_name("ID=x\n"), None);
    }

    #[test]
    fn plist_version() {
        let plist = "<dict><key>ProductName</key><string>macOS</string>\
                     <key>ProductVersion</key>\n\t<string>26.1</string></dict>";
        assert_eq!(
            plist_string(plist, "ProductVersion").as_deref(),
            Some("26.1")
        );
    }

    #[test]
    fn this_machine() {
        let info = build_info(DaemonFeatures::EMPTY);
        assert!(!info.hostname.is_empty());
        assert_eq!(info.protocol, proto::PROTOCOL_LEVEL);
        assert_eq!(info.arch, std::env::consts::ARCH);
    }
}
