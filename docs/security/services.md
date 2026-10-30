# Hosted services: push relay, push crypto, iroh relays

Scope: the Cloudflare Worker `services/push-relay`, the push formats in `crates/push` and
`apple/Packages/PushCrypto`, the Notification Service Extension and lock-screen actions
(`NotifyKit`), and the self-hosted `iroh-relay` (`services/iroh-relay`, docs/RELAYS.md).
Details of the push design: docs/PUSH.md.

## Assets

- **Notification content**: agent prompts, commands, host names. Sealed end to end.
- **The approval decision**: an Approve on the lock screen runs a tool call on the host.
- **The APNs `.p8` key**: whoever holds it can alert every install of the app.
- **The capability key** (`PUSH_CAP_KEY`): mints capabilities for any APNs token.
- **Relay bandwidth** (iroh relay) and **push budget** (Worker, APNs, the user's attention).
- **Metadata**: which device gets pushes from which host, when; client IPs.

## Attackers

1. Anyone on the internet calling the Worker or the iroh relay.
2. Someone who learned a device's APNs token (logs, a crash report, another SDK).
3. A compromised or malicious push relay (or Cloudflare, or Apple), which sees everything the
   Worker sees and can send arbitrary APNs payloads.
4. A network observer between daemon, relay and APNs (TLS only).
5. A stolen or replayed notification, and a stale one tapped after the host restarted.

## What we defend, and how

| Threat | Defence | Test |
|---|---|---|
| Reading notification content (2, 3, 4) | HPKE (X25519, ChaCha20-Poly1305) to the device's key; fresh ephemeral key per payload, so no nonce reuse | `cargo test -p push`, `swift test` in PushCrypto (shared vectors, RFC 9180 A.2.1) |
| Forging content (3) | Daemon Ed25519 signature inside the ciphertext, domain-separated; NSE checks the signer is a paired host; category taken from the signed payload | vectors: wrong signer, bit flip, wrong key |
| Forged push picking what Approve decides (3) | NSE drops every relay-supplied `userInfo` key except `aps` (also on timeout); the handler only reads local targets from local notifications | `relay_supplied_user_info_never_reaches_the_action_handler`, `aPushCannotPoseAsALocalApproval` |
| Approving the wrong request (5) | Daemon-signed action token bound to device, pane, request id, expiry (1 h) and a SHA-256 of the request as shown; re-checked against the open request; device signs the decision over an authenticated iroh connection; first decision wins; request ids random per run | `notify::approval_is_pushed_sealed_retried_and_answered_from_the_lock_screen` |
| Pushing as another daemon (1) | Ed25519 request signature, capability bound to the daemon key, push kind bound to the capability | Worker tests |
| Replaying a daemon request (1, 4) | ±5 min timestamp; nonce kept in the daemon's Durable Object until the request's own timestamp leaves the window (single-threaded object, input gates make check-and-set atomic) | `does not let a request with a future timestamp be replayed later` |
| Spamming a device via a leaked token (2) | Per-token budget across all daemons; per-daemon and per-IP (IPv6 /64) limits; content stays unreadable and Approve does nothing | `limits pushes per device token across daemons`, `counts a whole IPv6 /64 as one client` |
| Resource abuse of the Worker (1) | 8 KiB body cap enforced before buffering; strict JSON shapes; collapse id hex only (it becomes a header) | `refuses oversized bodies…`, `refuses header injection and loose types` |
| Targeting another app or environment (1) | APNs topic comes only from Worker config; environment fixed inside the sealed capability | Worker tests |
| Key leaks (all) | `.p8` and cap key only as Wrangler secrets; JWT key non-extractable; cap key rotation with `PUSH_CAP_KEY_PREVIOUS` | — |
| Information leaks (1) | Generic 500s; no CORS; `nosniff`, `no-store`, CSP `default-src 'none'`, HSTS; no invocation logs, no logging of tokens, IPs or payloads | `sends security headers and no CORS` |
| Open relay used as a free proxy (1) | `access.shared_token` required (compose refuses to start without it); per-connection accept limits and per-client byte limits | config reviewed against iroh-relay 1.3.0 |
| Relay container escape impact (1) | Non-root user, no capabilities, read-only root fs, `no-new-privileges`, memory/CPU/pids/log limits; metrics on loopback only | — |

## Residual risk

- **Unauthenticated `/v1/register`.** Anyone with a device's APNs token can bind it to a daemon
  of their own and send it placeholder alerts ("Approval needed"), up to the per-token budget
  (300 alerts an hour). They cannot show real-looking content or make Approve do anything.
  Signing registrations with the device key would not help: the relay has no accounts and
  cannot know which device key belongs to the token. Follow-ups, best first:
  1. **App Attest** on `/v1/register` (DCAppAttestService; the Worker verifies the attestation
     chain to Apple's App Attest root and keeps the key id): only a genuine app instance
     registers, and the app only registers its own token. Needs the paid account and a real
     device to build and test.
  2. **Proof of possession**: return the capability through a background push to the token
     itself (works only while the app is in the foreground, and not for Live Activity tokens).
- **A malicious relay** can drop, delay or replay what it received (APNs then shows an old,
  authentic notification; its action token is expired or its request already decided), send
  placeholder alerts, and learn timing, sizes, coarse category, client IPs and which daemon
  serves which token. It cannot read, forge or act.
- **Metadata at Apple and Cloudflare** (who gets pushes, when). Coalescing is left to the
  daemon's debounce; no further padding.
- **Durable Object cost**: two object calls per push (daemon, token). Workers Free covers
  normal use; a flood of unauthenticated requests only costs signature checks.
- **iroh relay token** is a shared secret carried in pairing tickets: every paired device can
  use the relay; rotation means re-pairing. QUIC address discovery (UDP 7842) answers anyone.
  The Docker setup has not been run on a real VPS; pin the image by digest in production.
- **Notification payload version** (`v`) is not checked by the NSE; there is only v1 today, so
  there is nothing to downgrade to. Notification and Live Activity payloads share a signature
  domain but cannot parse as each other.
