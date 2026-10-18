//! Private keys (decode, generate, export) and external signers (Secure Enclave).

use std::path::Path;
use std::sync::Arc;

use russh::keys::ssh_key::private::{Ed25519Keypair, KeypairData};
use russh::keys::ssh_key::{LineEnding, PrivateKey};
use russh::keys::{Algorithm, EcdsaCurve, HashAlg, PublicKey};

use crate::SshError;

/// A decoded private key, ready for authentication. Cheap to clone.
#[derive(Debug, Clone)]
pub struct SecretKey(pub(crate) Arc<PrivateKey>);

impl SecretKey {
    /// Decodes an OpenSSH, PKCS#8 or PKCS#1/SEC1 PEM private key (ed25519, ecdsa, rsa).
    ///
    /// # Errors
    ///
    /// Returns [`SshError::KeyEncrypted`] if the key is encrypted and `passphrase` is
    /// `None`, and [`SshError::Key`] for a wrong passphrase or an unreadable key.
    ///
    /// # Examples
    ///
    /// ```
    /// let generated = ssh::generate_ed25519("me@ipad").unwrap();
    /// let key = ssh::SecretKey::decode(&generated.private_key, None).unwrap();
    /// assert_eq!(key.public_key(), generated.public_key);
    /// ```
    pub fn decode(pem: &str, passphrase: Option<&str>) -> Result<Self, SshError> {
        let key = russh::keys::decode_secret_key(pem, passphrase).map_err(|e| match e {
            russh::keys::Error::KeyIsEncrypted => SshError::KeyEncrypted,
            other if passphrase.is_some() => SshError::Key(format!("{other} (wrong passphrase?)")),
            other => SshError::Key(other.to_string()),
        })?;
        Ok(Self(Arc::new(key)))
    }

    /// Reads and decodes a key file.
    ///
    /// # Errors
    ///
    /// As [`decode`](Self::decode), plus [`SshError::Io`] if the file cannot be read.
    pub fn load(path: impl AsRef<Path>, passphrase: Option<&str>) -> Result<Self, SshError> {
        let path = path.as_ref();
        let pem = std::fs::read_to_string(path)
            .map_err(|e| SshError::io(format!("reading {}", path.display()), e))?;
        Self::decode(&pem, passphrase)
    }

    /// Whether a PEM key is encrypted (so the UI can ask for the passphrase up front).
    pub fn is_encrypted(pem: &str) -> bool {
        matches!(
            russh::keys::decode_secret_key(pem, None),
            Err(russh::keys::Error::KeyIsEncrypted)
        )
    }

    /// The public key in OpenSSH format (`ssh-ed25519 AAAA… comment`).
    pub fn public_key(&self) -> String {
        public_openssh(self.0.public_key(), self.0.comment().as_str_lossy())
    }

    /// `SHA256:…` fingerprint.
    pub fn fingerprint(&self) -> String {
        self.0.fingerprint(HashAlg::Sha256).to_string()
    }

    /// Key type, e.g. `ssh-ed25519`.
    pub fn algorithm(&self) -> String {
        self.0.algorithm().as_str().to_owned()
    }
}

/// A freshly generated key pair.
#[derive(Debug, Clone)]
pub struct GeneratedKey {
    /// Unencrypted OpenSSH private key PEM (store it in the Keychain).
    pub private_key: String,
    /// Public key line for `authorized_keys`.
    pub public_key: String,
    /// `SHA256:…` fingerprint.
    pub fingerprint: String,
}

/// Generates an Ed25519 key pair from the OS random source.
///
/// # Errors
///
/// Returns [`SshError::Key`] if the OS random source or the encoder fails.
///
/// # Examples
///
/// ```
/// let key = ssh::generate_ed25519("ipad").unwrap();
/// assert!(key.public_key.starts_with("ssh-ed25519 "));
/// assert!(key.public_key.ends_with(" ipad"));
/// ```
pub fn generate_ed25519(comment: &str) -> Result<GeneratedKey, SshError> {
    let mut seed = [0u8; 32];
    getrandom::fill(&mut seed).map_err(|e| SshError::Key(format!("random source: {e}")))?;
    let keypair = Ed25519Keypair::from_seed(&seed);
    seed.fill(0);
    let key = PrivateKey::new(KeypairData::Ed25519(keypair), comment)
        .map_err(|e| SshError::Key(e.to_string()))?;
    let private_key = key
        .to_openssh(LineEnding::LF)
        .map_err(|e| SshError::Key(e.to_string()))?
        .to_string();
    Ok(GeneratedKey {
        private_key,
        public_key: public_openssh(key.public_key(), comment),
        fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
    })
}

fn public_openssh(key: &PublicKey, comment: &str) -> String {
    let mut key = key.clone();
    key.set_comment(comment);
    key.to_openssh().unwrap_or_default().trim().to_owned()
}

/// Error type for [`ExternalSigner`] implementations.
#[derive(Debug, Clone, thiserror::Error)]
#[error("{0}")]
pub struct SignerError(pub String);

/// A key whose private half lives elsewhere: the Secure Enclave (P-256), a hardware token,
/// another process. The app implements this; the crate asks it to sign during
/// authentication.
pub trait ExternalSigner: Send + Sync {
    /// The public key in OpenSSH format, e.g. `ecdsa-sha2-nistp256 AAAA…`.
    fn public_key(&self) -> String;

    /// Signs `data` and returns the raw signature: for ECDSA either `r ‖ s` (fixed width,
    /// what CryptoKit's `rawRepresentation` gives) or DER; for Ed25519 the 64-byte
    /// signature. ECDSA signers hash with the curve's hash (SHA-256 for P-256), as
    /// `P256.Signing.PrivateKey.signature(for:)` does.
    ///
    /// Runs on a blocking thread, so it may wait for biometry.
    ///
    /// # Errors
    ///
    /// Any [`SignerError`] (user cancelled, key missing) fails this auth method.
    fn sign(&self, data: Vec<u8>) -> Result<Vec<u8>, SignerError>;
}

/// Adapts an [`ExternalSigner`] to russh's signing hook.
pub(crate) struct ExternalSignerAdapter {
    pub signer: Arc<dyn ExternalSigner>,
    pub algorithm: Algorithm,
}

impl russh::Signer for ExternalSignerAdapter {
    type Error = SshError;

    async fn auth_sign(
        &mut self,
        _key: &russh::keys::agent::AgentIdentity,
        _hash_alg: Option<HashAlg>,
        to_sign: Vec<u8>,
    ) -> Result<Vec<u8>, Self::Error> {
        let signer = Arc::clone(&self.signer);
        let data = to_sign.clone();
        let raw = tokio::task::spawn_blocking(move || signer.sign(data))
            .await
            .map_err(|e| SshError::Signer(e.to_string()))?
            .map_err(|e| SshError::Signer(e.0))?;
        let blob = signature_blob(&self.algorithm, &raw)?;
        let mut out = to_sign;
        put_u32(&mut out, blob.len());
        out.extend_from_slice(&blob);
        Ok(out)
    }
}

/// Encodes a raw signature as the SSH signature blob `string(type) ‖ string(body)`.
pub(crate) fn signature_blob(algorithm: &Algorithm, raw: &[u8]) -> Result<Vec<u8>, SshError> {
    let body = match algorithm {
        Algorithm::Ed25519 => {
            if raw.len() != 64 {
                return Err(SshError::Signer(format!(
                    "an Ed25519 signature is 64 bytes, got {}",
                    raw.len()
                )));
            }
            raw.to_vec()
        }
        Algorithm::Ecdsa { curve } => {
            let width = match curve {
                EcdsaCurve::NistP256 => 32,
                EcdsaCurve::NistP384 => 48,
                EcdsaCurve::NistP521 => 66,
            };
            let (r, s) = if raw.len() == 2 * width {
                raw.split_at(width)
            } else {
                parse_der_signature(raw).ok_or_else(|| {
                    SshError::Signer(format!(
                        "an ECDSA signature must be r||s ({} bytes) or DER, got {} bytes",
                        2 * width,
                        raw.len()
                    ))
                })?
            };
            let mut body = Vec::with_capacity(2 * width + 10);
            put_mpint(&mut body, r);
            put_mpint(&mut body, s);
            body
        }
        other => {
            return Err(SshError::Signer(format!(
                "external signers support Ed25519 and ECDSA, not {}",
                other.as_str()
            )));
        }
    };
    let name = algorithm.as_str().as_bytes();
    let mut blob = Vec::with_capacity(8 + name.len() + body.len());
    put_string(&mut blob, name);
    put_string(&mut blob, &body);
    Ok(blob)
}

/// `SEQUENCE { INTEGER r, INTEGER s }` → (r, s) as unsigned big-endian bytes.
fn parse_der_signature(der: &[u8]) -> Option<(&[u8], &[u8])> {
    fn len_and_rest(b: &[u8]) -> Option<(usize, &[u8])> {
        let (&first, rest) = b.split_first()?;
        if first < 0x80 {
            return Some((usize::from(first), rest));
        }
        let n = usize::from(first & 0x7f);
        if n == 0 || n > 2 || rest.len() < n {
            return None;
        }
        let len = rest[..n]
            .iter()
            .fold(0usize, |acc, &b| (acc << 8) | usize::from(b));
        Some((len, &rest[n..]))
    }
    fn integer(b: &[u8]) -> Option<(&[u8], &[u8])> {
        let (&tag, rest) = b.split_first()?;
        if tag != 0x02 {
            return None;
        }
        let (len, rest) = len_and_rest(rest)?;
        if rest.len() < len {
            return None;
        }
        Some(rest.split_at(len))
    }
    let (&tag, rest) = der.split_first()?;
    if tag != 0x30 {
        return None;
    }
    let (len, rest) = len_and_rest(rest)?;
    if rest.len() != len {
        return None;
    }
    let (r, rest) = integer(rest)?;
    let (s, rest) = integer(rest)?;
    rest.is_empty().then_some((r, s))
}

fn put_u32(out: &mut Vec<u8>, n: usize) {
    let n = u32::try_from(n).expect("SSH fields are far below 4 GiB");
    out.extend_from_slice(&n.to_be_bytes());
}

fn put_string(out: &mut Vec<u8>, s: &[u8]) {
    put_u32(out, s.len());
    out.extend_from_slice(s);
}

fn put_mpint(out: &mut Vec<u8>, n: &[u8]) {
    let start = n.iter().position(|&b| b != 0).unwrap_or(n.len());
    let n = &n[start..];
    let pad = n.first().is_some_and(|&b| b & 0x80 != 0);
    put_u32(out, n.len() + usize::from(pad));
    if pad {
        out.push(0);
    }
    out.extend_from_slice(n);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_key_round_trips() {
        let g = generate_ed25519("test").unwrap();
        assert!(
            g.private_key
                .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----")
        );
        let k = SecretKey::decode(&g.private_key, None).unwrap();
        assert_eq!(k.public_key(), g.public_key);
        assert_eq!(k.fingerprint(), g.fingerprint);
        assert_eq!(k.algorithm(), "ssh-ed25519");
        assert!(!SecretKey::is_encrypted(&g.private_key));
        assert_ne!(generate_ed25519("x").unwrap().public_key, g.public_key);
    }

    #[test]
    fn mpint_encoding() {
        let mut v = Vec::new();
        put_mpint(&mut v, &[0x00, 0x00, 0x7f]);
        assert_eq!(v, [0, 0, 0, 1, 0x7f]);
        v.clear();
        put_mpint(&mut v, &[0x80, 0x01]);
        assert_eq!(v, [0, 0, 0, 3, 0, 0x80, 0x01]);
        v.clear();
        put_mpint(&mut v, &[0, 0]);
        assert_eq!(v, [0, 0, 0, 0]);
    }

    #[test]
    fn der_and_raw_ecdsa_encode_the_same() {
        let r = [0x80u8; 32];
        let mut s = [0x11u8; 32];
        s[0] = 0;
        let raw: Vec<u8> = r.iter().chain(s.iter()).copied().collect();
        // DER: r needs a leading 0 (high bit), s drops its leading zero.
        let mut der = vec![0x30, 0];
        der.extend([0x02, 33, 0]);
        der.extend(r);
        der.extend([0x02, 31]);
        der.extend(&s[1..]);
        der[1] = u8::try_from(der.len() - 2).unwrap();
        let alg = Algorithm::Ecdsa {
            curve: EcdsaCurve::NistP256,
        };
        assert_eq!(
            signature_blob(&alg, &raw).unwrap(),
            signature_blob(&alg, &der).unwrap()
        );
        assert!(signature_blob(&alg, &[1, 2, 3]).is_err());
        assert!(signature_blob(&Algorithm::Ed25519, &[0; 63]).is_err());
    }
}
