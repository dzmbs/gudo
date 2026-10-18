//!
//! - Remote - Tunnels: `vscode://vscode-remote/tunnel+<name>/<path>` (the daemon returns this
//!   in [`VsCodeTunnelOpened::desktop_uri`](proto::VsCodeTunnelOpened::desktop_uri)).
//! - Remote - SSH: `vscode://vscode-remote/ssh-remote+<authority>/<path>`. The authority is a
//!   `~/.ssh/config` alias, or, for a user, a port or an unusual host name, the hex-encoded
//!   JSON `{"hostName","user","port"}` that Remote - SSH itself writes (`toAuthorityString`
//!   in ms-vscode-remote.remote-ssh 0.129.2026100915).
//!
//! A host reachable only over iroh is reached by forwarding a local port to its sshd
//! ([`Client::forward`](crate::Client::forward) with `ForwardTarget::Tcp { port: 22 }`) and
//! pointing Remote - SSH at `127.0.0.1:<that port>` with [`ssh_authority`], or by an
//! `~/.ssh/config` host whose `ProxyCommand` is `un ssh-proxy` (stdio over the same link).
//!
//! VS Code opens a path ending in `:<line>` (optionally `:<col>`) as a file at that line, and
//! anything else as a folder.

/// A Remote - SSH host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshHost {
    /// Host name, address, or a `~/.ssh/config` alias.
    pub host: String,
    /// Login name; `None` uses the SSH config or the local user.
    pub user: Option<String>,
    /// Port; `None` uses the SSH config or 22.
    pub port: Option<u16>,
}

impl SshHost {
    /// A `~/.ssh/config` alias (or a plain host name).
    pub fn alias(host: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            user: None,
            port: None,
        }
    }

    /// `user@127.0.0.1:port`: a local forward to the host's sshd.
    pub fn local_forward(user: impl Into<String>, port: u16) -> Self {
        Self {
            host: "127.0.0.1".into(),
            user: Some(user.into()),
            port: Some(port),
        }
    }
}

/// The `ssh-remote+…` authority Remote - SSH uses for `host`.
///
/// # Examples
///
/// ```
/// use client_core::vscode::{SshHost, ssh_authority};
/// assert_eq!(ssh_authority(&SshHost::alias("box")), "ssh-remote+box");
/// // {"hostName":"127.0.0.1","user":"me","port":2222}
/// assert!(ssh_authority(&SshHost::local_forward("me", 2222)).starts_with("ssh-remote+7b22"));
/// ```
pub fn ssh_authority(host: &SshHost) -> String {
    let plain = host.user.is_none()
        && host.port.is_none()
        && !host.host.contains(['/', '\\', '+', '@', ':']);
    if plain {
        return format!("ssh-remote+{}", host.host);
    }
    let mut json = serde_json::Map::new();
    json.insert("hostName".into(), host.host.clone().into());
    if let Some(user) = &host.user {
        json.insert("user".into(), user.clone().into());
    }
    if let Some(port) = host.port {
        json.insert("port".into(), port.into());
    }
    let text = serde_json::Value::Object(json).to_string();
    let hex: String = text.bytes().map(|b| format!("{b:02x}")).collect();
    format!("ssh-remote+{hex}")
}

/// `vscode://vscode-remote/ssh-remote+…/<path>[:line[:col]]` for desktop VS Code with
/// Remote - SSH.
///
/// # Examples
///
/// ```
/// use client_core::vscode::{SshHost, remote_ssh_uri};
/// assert_eq!(
///     remote_ssh_uri(&SshHost::alias("box"), "/home/me/p/main.rs", Some(3), Some(5)),
///     "vscode://vscode-remote/ssh-remote+box/home/me/p/main.rs:3:5"
/// );
/// ```
pub fn remote_ssh_uri(
    host: &SshHost,
    path: &str,
    line: Option<u32>,
    column: Option<u32>,
) -> String {
    format!(
        "vscode://vscode-remote/{}{}{}",
        ssh_authority(host),
        encode_path(path),
        line_suffix(line, column)
    )
}

/// `vscode://vscode-remote/tunnel+<name>/<path>[:line[:col]]` for desktop VS Code with
/// Remote - Tunnels.
///
/// # Examples
///
/// ```
/// assert_eq!(
///     client_core::vscode::tunnel_uri("box", "/srv/a b", None, None),
///     "vscode://vscode-remote/tunnel+box/srv/a%20b"
/// );
/// ```
pub fn tunnel_uri(name: &str, path: &str, line: Option<u32>, column: Option<u32>) -> String {
    format!(
        "vscode://vscode-remote/tunnel+{name}{}{}",
        encode_path(path),
        line_suffix(line, column)
    )
}

/// `https://vscode.dev/tunnel/<name>/<folder>` for a browser or web view.
pub fn tunnel_web_url(name: &str, folder: &str) -> String {
    format!("https://vscode.dev/tunnel/{name}{}", encode_path(folder))
}

/// An `~/.ssh/config` entry that reaches the host's sshd through the daemon link, for users
/// who prefer an alias over a local port. `un` is the CLI that holds the pairing.
pub fn ssh_config_entry(alias: &str, user: &str, un: &str, ticket_arg: Option<&str>) -> String {
    let ticket = ticket_arg.map_or(String::new(), |t| format!(" --ticket {t}"));
    format!(
        "Host {alias}\n  HostName {alias}\n  User {user}\n  ProxyCommand {un}{ticket} ssh-proxy\n"
    )
}

fn line_suffix(line: Option<u32>, column: Option<u32>) -> String {
    match (line, column) {
        (Some(l), Some(c)) => format!(":{l}:{c}"),
        (Some(l), None) => format!(":{l}"),
        _ => String::new(),
    }
}

fn encode_path(path: &str) -> String {
    let mut out = String::with_capacity(path.len() + 1);
    if !path.starts_with('/') {
        out.push('/');
    }
    for b in path.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~/".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authority_matches_remote_ssh() {
        let a = ssh_authority(&SshHost::local_forward("me", 2222));
        let hex = a.strip_prefix("ssh-remote+").unwrap();
        let bytes: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect();
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            json,
            serde_json::json!({"hostName": "127.0.0.1", "user": "me", "port": 2222})
        );
        assert_eq!(ssh_authority(&SshHost::alias("box")), "ssh-remote+box");
        assert!(ssh_authority(&SshHost::alias("a+b")).starts_with("ssh-remote+7b"));
    }

    #[test]
    fn uris() {
        assert_eq!(
            tunnel_uri("box", "/p/main.rs", Some(1), None),
            "vscode://vscode-remote/tunnel+box/p/main.rs:1"
        );
        assert_eq!(
            tunnel_web_url("box", "/home/me"),
            "https://vscode.dev/tunnel/box/home/me"
        );
        assert!(ssh_config_entry("box-un", "me", "un", None).contains("ProxyCommand un ssh-proxy"));
    }
}
