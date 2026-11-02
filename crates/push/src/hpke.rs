//! HPKE (RFC 9180) base mode, single shot, for one ciphersuite:
//! DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305 (`0x0020`, `0x0001`, `0x0003`).
//!
//! This is the suite CryptoKit calls `HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly`, so the
//! Notification Service Extension opens what the daemon seals with
//! `HPKE.Recipient(privateKey:ciphersuite:info:encapsulatedKey:)` and no third-party code.
//! Only sequence number 0 is used (one message per encapsulation). Checked against the
//! RFC's appendix A.2 vectors in the tests.

use curve25519_dalek::montgomery::MontgomeryPoint;
use ring::{aead, hkdf, hmac};

/// Length of an X25519 key and of the encapsulated key.
pub const KEY_LEN: usize = 32;
/// Length of the Poly1305 tag added to every ciphertext.
pub const TAG_LEN: usize = 16;

const KEM_ID: [u8; 2] = [0x00, 0x20];
const KDF_ID: [u8; 2] = [0x00, 0x01];
const AEAD_ID: [u8; 2] = [0x00, 0x03];
const MODE_BASE: u8 = 0;

/// Why opening failed. Deliberately uninformative.
#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("cannot open the sealed message")]
pub struct OpenError;

fn kem_suite() -> Vec<u8> {
    [b"KEM".as_slice(), &KEM_ID].concat()
}

fn hpke_suite() -> Vec<u8> {
    [b"HPKE".as_slice(), &KEM_ID, &KDF_ID, &AEAD_ID].concat()
}

fn extract(salt: &[u8], ikm: &[u8]) -> [u8; 32] {
    let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, salt), ikm);
    tag.as_ref().try_into().expect("SHA-256 output")
}

struct OutputLen(usize);

impl hkdf::KeyType for OutputLen {
    fn len(&self) -> usize {
        self.0
    }
}

fn expand(prk: &[u8; 32], info: &[u8], len: usize) -> Vec<u8> {
    let prk = hkdf::Prk::new_less_safe(hkdf::HKDF_SHA256, prk);
    let mut out = vec![0; len];
    prk.expand(&[info], OutputLen(len))
        .and_then(|okm| okm.fill(&mut out))
        .expect("HKDF-SHA256 length within limits");
    out
}

fn labeled_extract(suite: &[u8], salt: &[u8], label: &[u8], ikm: &[u8]) -> [u8; 32] {
    extract(salt, &[b"HPKE-v1".as_slice(), suite, label, ikm].concat())
}

fn labeled_expand(suite: &[u8], prk: &[u8; 32], label: &[u8], info: &[u8], len: usize) -> Vec<u8> {
    let len_be = u16::try_from(len).expect("short output").to_be_bytes();
    let labeled = [&len_be[..], b"HPKE-v1", suite, label, info].concat();
    expand(prk, &labeled, len)
}

/// The X25519 public key of `secret`.
pub fn public_key(secret: &[u8; KEY_LEN]) -> [u8; KEY_LEN] {
    MontgomeryPoint::mul_base_clamped(*secret).to_bytes()
}

fn dh(secret: &[u8; KEY_LEN], public: &[u8; KEY_LEN]) -> Result<[u8; KEY_LEN], OpenError> {
    let shared = MontgomeryPoint(*public).mul_clamped(*secret).to_bytes();
    // RFC 9180 §7.1.4: an all-zero output (a small-order point) must be rejected.
    if shared == [0; KEY_LEN] {
        return Err(OpenError);
    }
    Ok(shared)
}

fn shared_secret(dh: &[u8; KEY_LEN], enc: &[u8; KEY_LEN], pk_r: &[u8; KEY_LEN]) -> [u8; 32] {
    let suite = kem_suite();
    let prk = labeled_extract(&suite, b"", b"eae_prk", dh);
    let context = [enc.as_slice(), pk_r].concat();
    labeled_expand(&suite, &prk, b"shared_secret", &context, 32)
        .try_into()
        .expect("32 bytes")
}

/// The AEAD key and base nonce for `shared_secret` and `info` (base mode, no PSK).
fn key_schedule(shared_secret: &[u8; 32], info: &[u8]) -> ([u8; 32], [u8; 12]) {
    let suite = hpke_suite();
    let psk_id_hash = labeled_extract(&suite, b"", b"psk_id_hash", b"");
    let info_hash = labeled_extract(&suite, b"", b"info_hash", info);
    let context = [&[MODE_BASE][..], &psk_id_hash, &info_hash].concat();
    let secret = labeled_extract(&suite, shared_secret, b"secret", b"");
    let key = labeled_expand(&suite, &secret, b"key", &context, 32);
    let nonce = labeled_expand(&suite, &secret, b"base_nonce", &context, 12);
    (
        key.try_into().expect("32 bytes"),
        nonce.try_into().expect("12 bytes"),
    )
}

fn aead_key(key: &[u8; 32]) -> aead::LessSafeKey {
    aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::CHACHA20_POLY1305, key).expect("32-byte key"),
    )
}

/// Seals `plaintext` to `recipient` with a fresh ephemeral key. Returns `(enc, ciphertext)`;
/// the ciphertext is `plaintext.len() + TAG_LEN` bytes.
///
/// # Errors
///
/// [`OpenError`] if `recipient` is a small-order point (not a usable public key).
pub fn seal(
    recipient: &[u8; KEY_LEN],
    info: &[u8],
    aad: &[u8],
    plaintext: &[u8],
) -> Result<([u8; KEY_LEN], Vec<u8>), OpenError> {
    let mut ephemeral = [0; KEY_LEN];
    getrandom::fill(&mut ephemeral).expect("the OS random source is available");
    seal_with_ephemeral(recipient, &ephemeral, info, aad, plaintext)
}

/// [`seal`] with a caller-chosen ephemeral secret: deterministic, for test vectors only.
///
/// # Errors
///
/// [`OpenError`] if `recipient` is a small-order point.
pub fn seal_with_ephemeral(
    recipient: &[u8; KEY_LEN],
    ephemeral: &[u8; KEY_LEN],
    info: &[u8],
    aad: &[u8],
    plaintext: &[u8],
) -> Result<([u8; KEY_LEN], Vec<u8>), OpenError> {
    let enc = public_key(ephemeral);
    let shared = shared_secret(&dh(ephemeral, recipient)?, &enc, recipient);
    let (key, nonce) = key_schedule(&shared, info);
    let mut sealed = plaintext.to_vec();
    aead_key(&key)
        .seal_in_place_append_tag(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::from(aad),
            &mut sealed,
        )
        .map_err(|_| OpenError)?;
    Ok((enc, sealed))
}

/// Opens a message sealed to the key pair of `secret`.
///
/// # Errors
///
/// [`OpenError`] if the ciphertext, `enc`, `info` or `aad` do not match.
pub fn open(
    secret: &[u8; KEY_LEN],
    enc: &[u8; KEY_LEN],
    info: &[u8],
    aad: &[u8],
    ciphertext: &[u8],
) -> Result<Vec<u8>, OpenError> {
    let pk_r = public_key(secret);
    let shared = shared_secret(&dh(secret, enc)?, enc, &pk_r);
    let (key, nonce) = key_schedule(&shared, info);
    let mut message = ciphertext.to_vec();
    let plaintext_len = aead_key(&key)
        .open_in_place(
            aead::Nonce::assume_unique_for_key(nonce),
            aead::Aad::from(aad),
            &mut message,
        )
        .map_err(|_| OpenError)?
        .len();
    message.truncate(plaintext_len);
    Ok(message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn h(hex: &str) -> Vec<u8> {
        data_encoding::HEXLOWER.decode(hex.as_bytes()).unwrap()
    }

    fn h32(hex: &str) -> [u8; 32] {
        h(hex).try_into().unwrap()
    }

    /// RFC 9180 appendix A.2.1 (base mode), sequence number 0.
    #[test]
    fn rfc9180_a21_base_vector() {
        let info = h("4f6465206f6e2061204772656369616e2055726e");
        let sk_e = h32("f4ec9b33b792c372c1d2c2063507b684ef925b8c75a42dbcbf57d63ccd381600");
        let pk_e = h32("1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a");
        let sk_r = h32("8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb");
        let pk_r = h32("4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a");
        assert_eq!(public_key(&sk_e), pk_e);
        assert_eq!(public_key(&sk_r), pk_r);

        let shared = shared_secret(&dh(&sk_e, &pk_r).unwrap(), &pk_e, &pk_r);
        assert_eq!(
            shared.to_vec(),
            h("0bbe78490412b4bbea4812666f7916932b828bba79942424abb65244930d69a7")
        );
        let (key, nonce) = key_schedule(&shared, &info);
        assert_eq!(
            key.to_vec(),
            h("ad2744de8e17f4ebba575b3f5f5a8fa1f69c2a07f6e7500bc60ca6e3e3ec1c91")
        );
        assert_eq!(nonce.to_vec(), h("5c4d98150661b848853b547f"));

        let plaintext = h("4265617574792069732074727574682c20747275746820626561757479");
        let aad = h("436f756e742d30");
        let ciphertext = h(
            "1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db21993c62ce81883d2dd1b51a28",
        );
        let (enc, sealed) = seal_with_ephemeral(&pk_r, &sk_e, &info, &aad, &plaintext).unwrap();
        assert_eq!(enc, pk_e);
        assert_eq!(sealed, ciphertext);
        assert_eq!(
            open(&sk_r, &enc, &info, &aad, &ciphertext).unwrap(),
            plaintext
        );
    }

    #[test]
    fn random_round_trip_and_tamper() {
        let secret = [7; 32];
        let public = public_key(&secret);
        let (enc, ciphertext) = seal(&public, b"i", b"a", b"hello").unwrap();
        assert_eq!(
            open(&secret, &enc, b"i", b"a", &ciphertext).unwrap(),
            b"hello"
        );
        assert_eq!(open(&secret, &enc, b"j", b"a", &ciphertext), Err(OpenError));
        assert_eq!(open(&secret, &enc, b"i", b"b", &ciphertext), Err(OpenError));
        let mut tampered = ciphertext.clone();
        tampered[0] ^= 1;
        assert_eq!(open(&secret, &enc, b"i", b"a", &tampered), Err(OpenError));
        assert_eq!(
            open(&[8; 32], &enc, b"i", b"a", &ciphertext),
            Err(OpenError)
        );
    }

    #[test]
    fn small_order_recipient_is_rejected() {
        assert!(seal_with_ephemeral(&[0; 32], &[1; 32], b"", b"", b"x").is_err());
    }
}
