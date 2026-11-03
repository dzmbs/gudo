//! What a desktop already has for SSH: key pairs in `~/.ssh`, identities in the ssh-agent,
//! and hosts in `known_hosts`. Private keys are never read here beyond checking whether
//! they are encrypted.

use std::path::{Path, PathBuf};

use russh::keys::PublicKey;
use russh::keys::agent::client::AgentClient;

use crate::SshError;

/// A public key as shown in a key picker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicKeyInfo {
    /// The OpenSSH line, comment included.
    pub public_key: String,
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `sk-ssh-ed25519@openssh.com`, …
    pub algorithm: String,
    pub comment: String,
    /// `SHA256:…`.
    pub fingerprint: String,
}

impl PublicKeyInfo {
    /// Reads an OpenSSH public key line (`type base64 [comment]`).
    ///
    /// # Errors
    ///
    /// Returns [`SshError::Key`] if the line is not a public key.
    ///
    /// # Examples
    ///
    /// ```
    /// let generated = ssh::generate_ed25519("me@mac").unwrap();
    /// let info = ssh::PublicKeyInfo::parse(&generated.public_key).unwrap();
    /// assert_eq!((info.algorithm.as_str(), info.comment.as_str()), ("ssh-ed25519", "me@mac"));
    /// assert_eq!(info.fingerprint, generated.fingerprint);
    /// ```
    pub fn parse(line: &str) -> Result<Self, SshError> {
        let key = PublicKey::from_openssh(line.trim())
            .map_err(|error| SshError::Key(format!("not a public key: {error}")))?;
        Ok(Self::from_key(&key, key.comment().as_str_lossy()))
    }

    pub(crate) fn from_key(key: &PublicKey, comment: &str) -> Self {
        let mut line = key.clone();
        line.set_comment(comment);
        Self {
            public_key: line.to_openssh().unwrap_or_default().trim().to_owned(),
            algorithm: key.algorithm().as_str().to_owned(),
            comment: comment.to_owned(),
            fingerprint: crate::fingerprint(key),
        }
    }
}

/// A key pair on disk: `name` and `name.pub` side by side.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalKey {
    /// The private key file.
    pub path: PathBuf,
    pub info: PublicKeyInfo,
    /// The private key needs a passphrase.
    pub encrypted: bool,
}

/// The key pairs in `directory` (usually `~/.ssh`), sorted by file name. A `.pub` file
/// without its private key, or one that is not a public key, is skipped.
///
/// # Examples
///
/// ```no_run
/// for key in ssh::local_keys(std::path::Path::new("/Users/me/.ssh")) {
///     println!("{} {}", key.info.algorithm, key.path.display());
/// }
/// ```
pub fn local_keys(directory: &Path) -> Vec<LocalKey> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut keys: Vec<LocalKey> = entries
        .flatten()
        .filter_map(|entry| {
            let public_path = entry.path();
            if public_path
                .extension()
                .is_none_or(|extension| extension != "pub")
            {
                return None;
            }
            let private_path = public_path.with_extension("");
            if !private_path.is_file() {
                return None;
            }
            let info = PublicKeyInfo::parse(&std::fs::read_to_string(&public_path).ok()?).ok()?;
            let encrypted = std::fs::read_to_string(&private_path)
                .is_ok_and(|pem| crate::SecretKey::is_encrypted(&pem));
            Some(LocalKey {
                path: private_path,
                info,
                encrypted,
            })
        })
        .collect();
    keys.sort_by(|a, b| a.path.cmp(&b.path));
    keys
}

/// The identities an ssh-agent holds: at `socket`, or `$SSH_AUTH_SOCK` when `None`.
/// Empty when there is no agent.
///
/// # Errors
///
/// Returns [`SshError::Signer`] if the agent answers with something unreadable.
pub async fn agent_keys(socket: Option<PathBuf>) -> Result<Vec<PublicKeyInfo>, SshError> {
    let Some(socket) = socket.or_else(|| std::env::var_os("SSH_AUTH_SOCK").map(PathBuf::from))
    else {
        return Ok(Vec::new());
    };
    let Ok(mut agent) = AgentClient::connect_uds(&socket).await else {
        return Ok(Vec::new());
    };
    let identities = agent
        .request_identities()
        .await
        .map_err(|error| SshError::Signer(format!("ssh-agent: {error}")))?;
    Ok(identities
        .iter()
        .map(|identity| PublicKeyInfo::from_key(&identity.public_key(), identity.comment()))
        .collect())
}

/// A host named in plain text in a known_hosts file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownHostName {
    pub host: String,
    pub port: u16,
}

/// The concrete hosts in known_hosts text, in file order without duplicates. Hashed
/// entries, wildcard patterns, negations, `@revoked` and `@cert-authority` lines are
/// skipped.
///
/// # Examples
///
/// ```
/// let text = "box,10.0.0.5 ssh-ed25519 AAAA\n[git.example.com]:2222 ssh-ed25519 AAAA\n";
/// let hosts = ssh::known_host_names(text);
/// assert_eq!(hosts.len(), 3);
/// assert_eq!((hosts[2].host.as_str(), hosts[2].port), ("git.example.com", 2222));
/// ```
pub fn known_host_names(text: &str) -> Vec<KnownHostName> {
    let mut hosts: Vec<KnownHostName> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with('@') {
            continue;
        }
        let Some(patterns) = line.split_whitespace().next() else {
            continue;
        };
        for pattern in patterns.split(',') {
            if pattern.starts_with('|') || pattern.contains(['*', '?', '!']) {
                continue;
            }
            let (host, port) = match pattern
                .strip_prefix('[')
                .and_then(|rest| rest.split_once("]:"))
            {
                Some((host, port)) => match port.parse() {
                    Ok(port) => (host, port),
                    Err(_) => continue,
                },
                None => (pattern, crate::DEFAULT_PORT),
            };
            let name = KnownHostName {
                host: host.to_owned(),
                port,
            };
            if !host.is_empty() && !hosts.contains(&name) {
                hosts.push(name);
            }
        }
    }
    hosts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_key_pairs() {
        let directory = tempfile::tempdir().unwrap();
        let plain = crate::generate_key(crate::KeyType::Ed25519, "plain@mac", None).unwrap();
        let locked =
            crate::generate_key(crate::KeyType::Ed25519, "locked@mac", Some("pw")).unwrap();
        let write =
            |name: &str, text: &str| std::fs::write(directory.path().join(name), text).unwrap();
        write("id_ed25519", &plain.private_key);
        write("id_ed25519.pub", &plain.public_key);
        write("work", &locked.private_key);
        write("work.pub", &format!("{}\n", locked.public_key));
        write("orphan.pub", &plain.public_key);
        write("config", "Host *\n");
        write("broken.pub", "not a key");
        write("broken", "");

        let keys = local_keys(directory.path());
        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].path, directory.path().join("id_ed25519"));
        assert_eq!(keys[0].info.comment, "plain@mac");
        assert_eq!(keys[0].info.fingerprint, plain.fingerprint);
        assert!(!keys[0].encrypted);
        assert_eq!(keys[1].info.comment, "locked@mac");
        assert!(keys[1].encrypted);
        assert!(local_keys(&directory.path().join("missing")).is_empty());
    }

    #[test]
    fn known_hosts_names() {
        let text = "\
# comment
box,10.0.0.5 ssh-ed25519 AAAA
|1|abc=|def= ssh-ed25519 AAAA
*.corp,!evil.corp ssh-rsa AAAA
@cert-authority *.example.com ssh-ed25519 AAAA
[box]:2222 ssh-ed25519 AAAA
box ecdsa-sha2-nistp256 AAAA
";
        let hosts: Vec<(String, u16)> = known_host_names(text)
            .into_iter()
            .map(|name| (name.host, name.port))
            .collect();
        assert_eq!(
            hosts,
            [
                ("box".to_owned(), 22),
                ("10.0.0.5".to_owned(), 22),
                ("box".to_owned(), 2222)
            ]
        );
    }

    #[tokio::test]
    async fn no_agent_is_empty() {
        let directory = tempfile::tempdir().unwrap();
        let keys = agent_keys(Some(directory.path().join("missing.sock")))
            .await
            .unwrap();
        assert!(keys.is_empty());
    }
}
