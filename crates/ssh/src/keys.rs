//! Private keys (decode, generate, export) and external signers (Secure Enclave).

use std::path::Path;
use std::sync::Arc;

use getrandom::SysRng;
use russh::keys::ssh_key::private::{Ed25519Keypair, KeypairData, RsaKeypair};
use russh::keys::ssh_key::rand_core::UnwrapErr;
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
        let key = russh::keys::decode_secret_key(pem, passphrase).map_err(|error| match error {
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
            .map_err(|error| SshError::io(format!("reading {}", path.display()), error))?;
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
    generate_key(KeyType::Ed25519, comment, None)
}

/// Key types the app generates in software.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyType {
    Ed25519,
    /// RSA 4096, for servers that accept nothing newer. Takes seconds to generate.
    Rsa4096,
}

/// Generates a key pair from the OS random source, its private key encrypted with
/// `passphrase` (bcrypt-pbkdf, aes256-ctr, as `ssh-keygen` does) when one is given.
///
/// # Errors
///
/// Returns [`SshError::Key`] if the OS random source or the encoder fails.
///
/// # Examples
///
/// ```
/// let key = ssh::generate_key(ssh::KeyType::Ed25519, "ipad", Some("correct horse")).unwrap();
/// assert!(ssh::SecretKey::is_encrypted(&key.private_key));
/// let decoded = ssh::SecretKey::decode(&key.private_key, Some("correct horse")).unwrap();
/// assert_eq!(decoded.fingerprint(), key.fingerprint);
/// ```
pub fn generate_key(
    key_type: KeyType,
    comment: &str,
    passphrase: Option<&str>,
) -> Result<GeneratedKey, SshError> {
    let key_error = |error: russh::keys::ssh_key::Error| SshError::Key(error.to_string());
    let keypair = match key_type {
        KeyType::Ed25519 => {
            let mut seed = [0u8; 32];
            getrandom::fill(&mut seed)
                .map_err(|error| SshError::Key(format!("random source: {error}")))?;
            let keypair = Ed25519Keypair::from_seed(&seed);
            seed.fill(0);
            KeypairData::Ed25519(keypair)
        }
        KeyType::Rsa4096 => {
            let mut rng = UnwrapErr(SysRng);
            KeypairData::Rsa(RsaKeypair::random(&mut rng, 4096).map_err(key_error)?)
        }
    };
    let mut key = PrivateKey::new(keypair, comment).map_err(key_error)?;
    if let Some(passphrase) = passphrase.filter(|passphrase| !passphrase.is_empty()) {
        key = key.encrypt(&mut SysRng, passphrase).map_err(key_error)?;
    }
    let private_key = key
        .to_openssh(LineEnding::LF)
        .map_err(key_error)?
        .to_string();
    Ok(GeneratedKey {
        private_key,
        public_key: public_openssh(key.public_key(), comment),
        fingerprint: key.fingerprint(HashAlg::Sha256).to_string(),
    })
}

/// A shell command that appends `public_key` to `~/.ssh/authorized_keys` unless it is
/// already there, creating the directory and file with OpenSSH's permissions (what
/// `ssh-copy-id` does). Safe to run under `sh -c`: the key is validated and quoted.
///
/// # Errors
///
/// Returns [`SshError::Key`] if `public_key` is not one OpenSSH public key line.
///
/// # Examples
///
/// ```
/// let key = ssh::generate_ed25519("ipad").unwrap();
/// let command = ssh::authorize_key_command(&key.public_key).unwrap();
/// assert!(command.contains("authorized_keys"));
/// assert!(ssh::authorize_key_command("ssh-ed25519 AAAA'; rm -rf ~ #").is_err());
/// ```
pub fn authorize_key_command(public_key: &str) -> Result<String, SshError> {
    let line = public_key.trim();
    if line.contains(['\n', '\r']) {
        return Err(SshError::Key("one public key at a time".into()));
    }
    let parsed = PublicKey::from_openssh(line)
        .map_err(|error| SshError::Key(format!("not a public key: {error}")))?;
    let line = public_openssh(&parsed, parsed.comment().as_str_lossy());
    let quoted = crate::shell_quote(&line);
    Ok(format!(
        "umask 077 && mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && \
         chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && \
         {{ grep -qxF {quoted} ~/.ssh/authorized_keys || \
         {{ [ -s ~/.ssh/authorized_keys ] && [ -n \"$(tail -c 1 ~/.ssh/authorized_keys)\" ] && echo >> ~/.ssh/authorized_keys; \
         echo {quoted} >> ~/.ssh/authorized_keys; }}; }}"
    ))
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

    /// For a FIDO2 security key (an `sk-…` public key): a CTAP2 assertion with
    /// `rpId` = the key's application (`ssh:`) and `clientDataHash` = SHA-256 of `data`.
    /// The authenticator signs `SHA256(application) ‖ flags ‖ counter ‖ SHA256(data)`.
    ///
    /// # Errors
    ///
    /// Any [`SignerError`] (no key tapped, cancelled) fails this auth method. The default
    /// refuses: only security-key signers implement it.
    fn sign_security_key(&self, data: Vec<u8>) -> Result<SecurityKeySignature, SignerError> {
        drop(data);
        Err(SignerError("this signer is not a security key".into()))
    }
}

/// What a security key returns for one assertion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecurityKeySignature {
    /// ECDSA `r ‖ s` or DER, or the 64-byte Ed25519 signature.
    pub signature: Vec<u8>,
    /// The authenticator data flags (user present = `0x01`, verified = `0x04`).
    pub flags: u8,
    /// The authenticator's signature counter.
    pub counter: u32,
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
        let blob = if is_security_key(&self.algorithm) {
            let signed = tokio::task::spawn_blocking(move || signer.sign_security_key(data))
                .await
                .map_err(|error| SshError::Signer(error.to_string()))?
                .map_err(|error| SshError::Signer(error.0))?;
            security_key_blob(&self.algorithm, &signed)?
        } else {
            let raw = tokio::task::spawn_blocking(move || signer.sign(data))
                .await
                .map_err(|error| SshError::Signer(error.to_string()))?
                .map_err(|error| SshError::Signer(error.0))?;
            signature_blob(&self.algorithm, &raw)?
        };
        let mut signed = to_sign;
        put_u32(&mut signed, blob.len());
        signed.extend_from_slice(&blob);
        Ok(signed)
    }
}

fn is_security_key(algorithm: &Algorithm) -> bool {
    matches!(
        algorithm,
        Algorithm::SkEd25519 | Algorithm::SkEcdsaSha2NistP256
    )
}

/// Encodes a raw signature as the SSH signature blob `string(type) ‖ string(body)`.
pub(crate) fn signature_blob(algorithm: &Algorithm, raw: &[u8]) -> Result<Vec<u8>, SshError> {
    let body = signature_body(algorithm, raw)?;
    let name = algorithm.as_str().as_bytes();
    let mut blob = Vec::with_capacity(8 + name.len() + body.len());
    put_string(&mut blob, name);
    put_string(&mut blob, &body);
    Ok(blob)
}

/// The OpenSSH security-key signature blob (PROTOCOL.u2f): `string(type) ‖ string(body)
/// ‖ byte(flags) ‖ uint32(counter)`, the body encoded as for the plain key type.
pub(crate) fn security_key_blob(
    algorithm: &Algorithm,
    signed: &SecurityKeySignature,
) -> Result<Vec<u8>, SshError> {
    let plain = match algorithm {
        Algorithm::SkEd25519 => Algorithm::Ed25519,
        Algorithm::SkEcdsaSha2NistP256 => Algorithm::Ecdsa {
            curve: EcdsaCurve::NistP256,
        },
        other => {
            return Err(SshError::Signer(format!(
                "{} is not a security key type",
                other.as_str()
            )));
        }
    };
    let mut blob = Vec::new();
    put_string(&mut blob, algorithm.as_str().as_bytes());
    put_string(&mut blob, &signature_body(&plain, &signed.signature)?);
    blob.push(signed.flags);
    blob.extend_from_slice(&signed.counter.to_be_bytes());
    Ok(blob)
}

fn signature_body(algorithm: &Algorithm, raw: &[u8]) -> Result<Vec<u8>, SshError> {
    Ok(match algorithm {
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
    })
}

/// `SEQUENCE { INTEGER r, INTEGER s }` → (r, s) as unsigned big-endian bytes.
fn parse_der_signature(der: &[u8]) -> Option<(&[u8], &[u8])> {
    fn len_and_rest(bytes: &[u8]) -> Option<(usize, &[u8])> {
        let (&first, rest) = bytes.split_first()?;
        if first < 0x80 {
            return Some((usize::from(first), rest));
        }
        let len_octets = usize::from(first & 0x7f);
        if len_octets == 0 || len_octets > 2 || rest.len() < len_octets {
            return None;
        }
        let len = rest[..len_octets]
            .iter()
            .fold(0usize, |acc, &byte| (acc << 8) | usize::from(byte));
        Some((len, &rest[len_octets..]))
    }
    fn integer(bytes: &[u8]) -> Option<(&[u8], &[u8])> {
        let (&tag, rest) = bytes.split_first()?;
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

fn put_u32(out: &mut Vec<u8>, value: usize) {
    let value = u32::try_from(value).expect("SSH fields are far below 4 GiB");
    out.extend_from_slice(&value.to_be_bytes());
}

fn put_string(out: &mut Vec<u8>, bytes: &[u8]) {
    put_u32(out, bytes.len());
    out.extend_from_slice(bytes);
}

fn put_mpint(out: &mut Vec<u8>, big_endian: &[u8]) {
    let start = big_endian
        .iter()
        .position(|&byte| byte != 0)
        .unwrap_or(big_endian.len());
    let magnitude = &big_endian[start..];
    let needs_pad = magnitude.first().is_some_and(|&byte| byte & 0x80 != 0);
    put_u32(out, magnitude.len() + usize::from(needs_pad));
    if needs_pad {
        out.push(0);
    }
    out.extend_from_slice(magnitude);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_key_round_trips() {
        let generated = generate_ed25519("test").unwrap();
        assert!(
            generated
                .private_key
                .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----")
        );
        let key = SecretKey::decode(&generated.private_key, None).unwrap();
        assert_eq!(key.public_key(), generated.public_key);
        assert_eq!(key.fingerprint(), generated.fingerprint);
        assert_eq!(key.algorithm(), "ssh-ed25519");
        assert!(!SecretKey::is_encrypted(&generated.private_key));
        assert_ne!(
            generate_ed25519("x").unwrap().public_key,
            generated.public_key
        );
    }

    #[test]
    fn passphrase_protected_key() {
        let generated = generate_key(KeyType::Ed25519, "locked", Some("s3cret")).unwrap();
        assert!(SecretKey::is_encrypted(&generated.private_key));
        assert!(matches!(
            SecretKey::decode(&generated.private_key, None),
            Err(SshError::KeyEncrypted)
        ));
        assert!(SecretKey::decode(&generated.private_key, Some("wrong")).is_err());
        let key = SecretKey::decode(&generated.private_key, Some("s3cret")).unwrap();
        assert_eq!(key.public_key(), generated.public_key);
        let empty = generate_key(KeyType::Ed25519, "open", Some("")).unwrap();
        assert!(!SecretKey::is_encrypted(&empty.private_key));
    }

    #[test]
    fn rsa_4096() {
        let generated = generate_key(KeyType::Rsa4096, "old-server", None).unwrap();
        assert!(generated.public_key.starts_with("ssh-rsa "));
        let key = SecretKey::decode(&generated.private_key, None).unwrap();
        assert_eq!(key.algorithm(), "ssh-rsa");
        assert_eq!(key.fingerprint(), generated.fingerprint);
        let info = crate::PublicKeyInfo::parse(&generated.public_key).unwrap();
        assert_eq!(info.comment, "old-server");
    }

    #[test]
    fn authorize_key_appends_once() {
        let home = tempfile::tempdir().unwrap();
        let first = generate_ed25519("it's me").unwrap();
        let second = generate_ed25519("second").unwrap();
        let ssh = home.path().join(".ssh");
        std::fs::create_dir_all(&ssh).unwrap();
        std::fs::write(ssh.join("authorized_keys"), "ssh-ed25519 AAAAexisting old").unwrap();
        let run = |public_key: &str| {
            let command = authorize_key_command(public_key).unwrap();
            let status = std::process::Command::new("sh")
                .arg("-c")
                .arg(command)
                .env("HOME", home.path())
                .status()
                .unwrap();
            assert!(status.success());
        };
        run(&first.public_key);
        run(&format!("  {}\n", first.public_key));
        run(&second.public_key);
        let text = std::fs::read_to_string(ssh.join("authorized_keys")).unwrap();
        assert_eq!(
            text,
            format!(
                "ssh-ed25519 AAAAexisting old\n{}\n{}\n",
                first.public_key, second.public_key
            )
        );
        use std::os::unix::fs::PermissionsExt;
        let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&ssh), 0o700);
        assert_eq!(mode(&ssh.join("authorized_keys")), 0o600);
        assert!(
            authorize_key_command(&format!("{}\n{}", first.public_key, second.public_key)).is_err()
        );
        assert!(authorize_key_command("command=\"x\" ssh-ed25519 AAAA").is_err());
    }

    #[test]
    fn mpint_encoding() {
        let mut encoded = Vec::new();
        put_mpint(&mut encoded, &[0x00, 0x00, 0x7f]);
        assert_eq!(encoded, [0, 0, 0, 1, 0x7f]);
        encoded.clear();
        put_mpint(&mut encoded, &[0x80, 0x01]);
        assert_eq!(encoded, [0, 0, 0, 3, 0, 0x80, 0x01]);
        encoded.clear();
        put_mpint(&mut encoded, &[0, 0]);
        assert_eq!(encoded, [0, 0, 0, 0]);
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
        let algorithm = Algorithm::Ecdsa {
            curve: EcdsaCurve::NistP256,
        };
        assert_eq!(
            signature_blob(&algorithm, &raw).unwrap(),
            signature_blob(&algorithm, &der).unwrap()
        );
        assert!(signature_blob(&algorithm, &[1, 2, 3]).is_err());
        assert!(signature_blob(&Algorithm::Ed25519, &[0; 63]).is_err());
    }

    /// A software authenticator signing as a FIDO2 key does; OpenSSH's verifier (as
    /// ssh-key implements PROTOCOL.u2f) must accept the blob.
    #[test]
    fn security_key_signature_verifies() {
        use p256::ecdsa::signature::Signer as _;
        use russh::keys::signature::Verifier as _;
        use sha2_for_tests::sha256;

        let authenticator = p256::ecdsa::SigningKey::from_slice(&[7u8; 32]).unwrap();
        let point = authenticator.verifying_key().to_sec1_bytes();
        let mut wire = Vec::new();
        put_string(&mut wire, b"sk-ecdsa-sha2-nistp256@openssh.com");
        put_string(&mut wire, b"nistp256");
        put_string(&mut wire, &point);
        put_string(&mut wire, b"ssh:");
        let public_key = PublicKey::from_bytes(&wire).unwrap();
        assert_eq!(public_key.algorithm(), Algorithm::SkEcdsaSha2NistP256);

        let message = b"session id and userauth request".to_vec();
        let (flags, counter) = (0x01u8, 42u32);
        let mut signed_data = sha256(b"ssh:").to_vec();
        signed_data.push(flags);
        signed_data.extend_from_slice(&counter.to_be_bytes());
        signed_data.extend_from_slice(&sha256(&message));
        let signature: p256::ecdsa::Signature = authenticator.sign(&signed_data);

        let signed = SecurityKeySignature {
            signature: signature.to_bytes().to_vec(),
            flags,
            counter,
        };
        let blob = security_key_blob(&Algorithm::SkEcdsaSha2NistP256, &signed).unwrap();
        let decoded = russh::keys::ssh_key::Signature::try_from(&blob[..]).unwrap();
        public_key.key_data().verify(&message, &decoded).unwrap();
        assert!(
            public_key
                .key_data()
                .verify(b"another message", &decoded)
                .is_err()
        );
        let tampered = SecurityKeySignature {
            counter: 43,
            ..signed
        };
        let blob = security_key_blob(&Algorithm::SkEcdsaSha2NistP256, &tampered).unwrap();
        let decoded = russh::keys::ssh_key::Signature::try_from(&blob[..]).unwrap();
        assert!(public_key.key_data().verify(&message, &decoded).is_err());
        assert!(security_key_blob(&Algorithm::Ed25519, &tampered).is_err());
    }

    mod sha2_for_tests {
        pub fn sha256(data: &[u8]) -> [u8; 32] {
            let digest = ring::digest::digest(&ring::digest::SHA256, data);
            digest.as_ref().try_into().unwrap()
        }
    }
}
