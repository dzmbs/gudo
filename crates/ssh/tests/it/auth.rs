//! Authentication and host-key trust against the real sshd.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use p256::ecdsa::signature::Signer as _;
use ssh::{
    AuthMethod, ConnectOptions, Connection, Credentials, ExternalSigner, HostKeyInfo,
    HostKeyPolicy, HostKeyPrompt, KnownHosts, SecretKey, SignerError, SshError,
};

use crate::common::env;

async fn whoami(creds: Credentials) -> Result<String, SshError> {
    let env = env();
    let conn = Connection::connect(&env.target(), &env.options(creds)).await?;
    let out = conn.exec("whoami").await?.check()?;
    Ok(out.stdout_text().trim().to_owned())
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn password() {
    let env = env();
    let user = whoami(Credentials::new().with(AuthMethod::Password(env.password.clone())))
        .await
        .unwrap();
    assert_eq!(user, env.user);
    let wrong = whoami(Credentials::new().with(AuthMethod::Password("nope".into()))).await;
    match wrong {
        Err(SshError::AuthFailed { tried, .. }) => assert!(tried.contains("password")),
        other => panic!("{other:?}"),
    }
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn every_key_type() {
    let env = env();
    for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
        let user = whoami(Credentials::new().with(AuthMethod::Key(env.key(name))))
            .await
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(user, env.user, "{name}");
    }
    let pem = std::fs::read_to_string(env.keys.join("id_ed25519_enc")).unwrap();
    assert!(SecretKey::is_encrypted(&pem));
    assert!(matches!(
        SecretKey::decode(&pem, None),
        Err(SshError::KeyEncrypted)
    ));
    assert!(SecretKey::decode(&pem, Some("wrong")).is_err());
    let key = SecretKey::decode(&pem, Some("test passphrase")).unwrap();
    assert_eq!(
        whoami(Credentials::new().with(AuthMethod::Key(key)))
            .await
            .unwrap(),
        env.user
    );
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn falls_through_to_the_next_method() {
    let env = env();
    // An unknown key first, then the right one.
    let stranger =
        SecretKey::decode(&ssh::generate_ed25519("x").unwrap().private_key, None).unwrap();
    let creds = Credentials::new()
        .with(AuthMethod::Key(stranger))
        .with(AuthMethod::Key(env.key("id_ecdsa")));
    assert_eq!(whoami(creds).await.unwrap(), env.user);
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn ssh_agent() {
    let env = env();
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("agent.sock");
    let mut agent = tokio::process::Command::new("ssh-agent")
        .args(["-D", "-a"])
        .arg(&sock)
        .stdout(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    assert!(crate::common::eventually(std::time::Duration::from_secs(5), || sock.exists()).await);
    let status = tokio::process::Command::new("ssh-add")
        .arg(env.keys.join("id_ed25519"))
        .env("SSH_AUTH_SOCK", &sock)
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .unwrap();
    assert!(status.success());
    let user = whoami(Credentials::new().with(AuthMethod::Agent(Some(sock.clone()))))
        .await
        .unwrap();
    assert_eq!(user, env.user);
    agent.kill().await.unwrap();
}

/// A software P-256 key behind the [`ExternalSigner`] interface, standing in for the
/// Secure Enclave (which returns `r ‖ s` from CryptoKit).
struct SoftEnclave {
    key: p256::ecdsa::SigningKey,
    der: bool,
    calls: AtomicUsize,
}

impl SoftEnclave {
    fn new(der: bool) -> Self {
        let mut seed = [0u8; 32];
        loop {
            getrandom::fill(&mut seed).unwrap();
            if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&seed) {
                return Self {
                    key,
                    der,
                    calls: AtomicUsize::new(0),
                };
            }
        }
    }
}

impl ExternalSigner for SoftEnclave {
    fn public_key(&self) -> String {
        let point = self.key.verifying_key().to_sec1_point(false);
        let key_data = ssh::PublicKey::from_openssh(&openssh_p256(point.as_bytes())).unwrap();
        key_data.to_openssh().unwrap()
    }

    fn sign(&self, data: Vec<u8>) -> Result<Vec<u8>, SignerError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let sig: p256::ecdsa::Signature = self.key.sign(&data);
        Ok(if self.der {
            sig.to_der().as_bytes().to_vec()
        } else {
            sig.to_bytes().to_vec()
        })
    }
}

/// Builds `ecdsa-sha2-nistp256 <base64>` from an uncompressed SEC1 point.
fn openssh_p256(point: &[u8]) -> String {
    let mut blob = Vec::new();
    for field in [&b"ecdsa-sha2-nistp256"[..], b"nistp256", point] {
        blob.extend_from_slice(&u32::try_from(field.len()).unwrap().to_be_bytes());
        blob.extend_from_slice(field);
    }
    format!(
        "ecdsa-sha2-nistp256 {}",
        data_encoding::BASE64.encode(&blob)
    )
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn external_signer_secure_enclave_style() {
    let env = env();
    let admin = env.connect().await;
    for der in [false, true] {
        let enclave = Arc::new(SoftEnclave::new(der));
        let line = enclave.public_key();
        assert!(line.starts_with("ecdsa-sha2-nistp256 "));
        admin
            .exec(&format!(
                "echo {} >> ~/.ssh/authorized_keys",
                ssh::shell_quote(&format!("{line} soft-enclave"))
            ))
            .await
            .unwrap()
            .check()
            .unwrap();
        let signer: Arc<dyn ExternalSigner> = enclave.clone();
        let user = whoami(Credentials::new().with(AuthMethod::External(signer))).await;
        admin
            .exec("sed -i '/soft-enclave$/d' ~/.ssh/authorized_keys")
            .await
            .unwrap()
            .check()
            .unwrap();
        assert_eq!(user.unwrap(), env.user, "der={der}");
        assert_eq!(enclave.calls.load(Ordering::SeqCst), 1);
    }
}

#[derive(Default)]
struct Prompt {
    answer: bool,
    seen: Mutex<Vec<HostKeyInfo>>,
}

impl HostKeyPrompt for Prompt {
    fn trust_new_host(&self, key: HostKeyInfo) -> bool {
        self.seen.lock().unwrap().push(key);
        self.answer
    }
}

#[tokio::test]
#[cfg_attr(not(ssh_test_host), ignore = "needs GUDO_SSH_TEST_HOST (docs/SSH.md)")]
async fn host_keys_tofu_pin_and_mismatch() {
    let env = env();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("known_hosts");
    let known = Arc::new(KnownHosts::open(&path).unwrap());

    // Refused on first sight: nothing is recorded and no credentials are sent.
    let no = Arc::new(Prompt::default());
    let options = ConnectOptions::new(
        env.key_creds(),
        Arc::clone(&known),
        HostKeyPolicy::Ask(no.clone()),
    );
    match Connection::connect(&env.target(), &options).await {
        Err(SshError::HostKeyRejected { host, fingerprint }) => {
            assert_eq!(host, env.host);
            assert!(fingerprint.starts_with("SHA256:"));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(no.seen.lock().unwrap().len(), 1);
    assert!(known.to_text().is_empty());

    // Trusted on first sight: asked once, then remembered (in the file too).
    let yes = Arc::new(Prompt {
        answer: true,
        ..Prompt::default()
    });
    let options = ConnectOptions::new(
        env.key_creds(),
        Arc::clone(&known),
        HostKeyPolicy::Ask(yes.clone()),
    );
    Connection::connect(&env.target(), &options).await.unwrap();
    Connection::connect(&env.target(), &options).await.unwrap();
    assert_eq!(yes.seen.lock().unwrap().len(), 1);
    let real = yes.seen.lock().unwrap()[0].clone();
    let reopened = KnownHosts::open(&path).unwrap();
    assert!(reopened.to_text().contains(&real.public_key));

    // Pinned to another key: a hard mismatch carrying both fingerprints.
    let other = ssh::generate_ed25519("").unwrap();
    known.pin(&env.host, 22, &other.public_key).unwrap();
    match Connection::connect(&env.target(), &options).await {
        Err(e @ SshError::HostKeyMismatch { .. }) => {
            let SshError::HostKeyMismatch {
                expected, actual, ..
            } = &e
            else {
                unreachable!()
            };
            assert_eq!(expected, std::slice::from_ref(&other.fingerprint));
            assert_eq!(actual, &real.fingerprint);
            assert!(e.is_fatal());
            assert!(e.to_string().contains(&other.fingerprint));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        yes.seen.lock().unwrap().len(),
        1,
        "a mismatch never prompts"
    );

    // Strict refuses unknown hosts outright.
    let strict = ConnectOptions::new(
        env.key_creds(),
        Arc::new(KnownHosts::in_memory()),
        HostKeyPolicy::Strict,
    );
    assert!(matches!(
        Connection::connect(&env.target(), &strict).await,
        Err(SshError::HostKeyRejected { .. })
    ));
}
