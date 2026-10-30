# Transport, identity, pairing and multiplayer

## Assets

- **The daemon key** (`daemon.key`): it identifies the host. Anyone holding it can pose as the
  host to paired devices.
- **The owner allowlist** (`devices.json`): every device on it is a full owner, with a shell as
  the user.
- **Pairing secrets** (`pairing.json`, the `unnamed://pair/…` ticket and QR code): one secret
  makes one new owner device.
- **Grant chains and invite links** (`grants.json`, `unnamed://join/…`): each is access for a
  guest, from viewing up to driving or approving.
- **The audit log** (`audit/audit.jsonl`, hash-chained): what happened and who did it.
- **Traffic**: terminal output, keystrokes, files, approvals and forwarded ports.

## Attackers

- **On the network path or running a relay.** Can see, drop or replay packets, but holds no
  key.
- **A stranger who knows the daemon id.** For example from an old ticket, an invite or a log.
  They can connect with any key they like.
- **A guest** with a valid invite, who tries to do more than their role allows or to stay
  after being removed.
- **A thief with a lost or stolen phone** that is paired as an owner.
- **A phisher** who gets a pairing link or QR code in front of someone, or who sees one in a log,
  screenshot or link preview.
- **A hostile daemon** that a guest joins (someone else's host).
- **Another local user** on the host who can read logs.

## What we defend, and how

### Confidentiality and integrity in transit

- All traffic runs over iroh QUIC with TLS 1.3. Clients dial by key, so the TLS handshake pins
  the daemon's Ed25519 key, and the client's own key is proven in the same handshake.
- A relay only forwards encrypted QUIC packets. It cannot read or modify them.
- What a relay does see: both endpoint ids, IP addresses, timing and sizes. Self-hosted relays
  (docs/RELAYS.md) keep this metadata in the owner's hands.
- The ALPN is `unnamed/1`. There is no weaker protocol version to downgrade to.
- 0-RTT is never used:
  - The daemon waits for the full handshake before it reads anything.
  - The client does not send early data.
  - So nothing can be replayed into a request.

### Pairing

- **The secret.** 128 bits from the OS random source, one per ticket. It expires after 10
  minutes by default, and the expiry is enforced by the daemon from `pairing.json`, not taken
  from the ticket text.
- **One device per secret.** The daemon consumes the secret under a file lock in the same
  step as checking it, so one secret cannot pair two devices (compare Tailscale TS-2025-007).
  A concurrency test covers this.
- **Checking a guess.** Secrets are compared in constant time. A wrong guess causes no disk
  write, so strangers cannot turn pairing attempts into disk load.
- **No ticket in logs.** The ticket is never logged. The daemon prints its startup ticket only
  when stderr is a terminal. Under systemd, launchd or the SSH bootstrap, stderr goes to a log
  file or the journal, where other users could read it.
- **State files.** `daemon.key`, `owner.json`, `devices.json` and `pairing.json` are written
  atomically: a temporary file, fsync, then rename. Each file is mode 0600, and the state
  directory is 0700. A test checks these modes.
- **New pairings are announced.** Every other connected owner device gets
  `ServerCtl::DevicePaired`, and the app shows "A new device paired with this host". This is
  the defence against Signal- and WhatsApp-style linked-device phishing. Each pairing is also
  recorded in the audit log.

### Device lifecycle (lost phone)

- **In the app:** Access → Devices → Remove (`Revoke(Device)`). This closes the device's
  connections at once. Its later connection attempts are refused with `Revoked`.
- **On the host:**
  - `unnamed-hostd devices` lists the owner devices.
  - `unnamed-hostd unpair <key prefix>` removes one.
  - The daemon re-reads `devices.json` whenever the file changes, so removal takes effect
    within 0.5 s without a restart.
- **Guests the device invited.** Removing an owner device in either way also cuts off the guests
  whose invites that device signed:
  - Every live check confirms that the chain's root is still trusted and that no signer has
    been revoked.
  - A thief therefore cannot keep access by inviting their own second key before the phone
    is removed.
- **No accidental return.** A pairing never brings back a device that was removed, because
  every change to `devices.json` is a locked read-modify-write of the file as it is now.

### Handshake

- **Order of checks:**
  1. `Hello.device_id` must equal the key proven by TLS.
  2. The key must not be of small order. With such a key, anyone can produce valid signatures,
     and the TLS layer (ring) accepts them.
  3. The grant is checked.
- **Nothing before the `Hello`.** The daemon processes no request before the `Hello` has been
  accepted.
- **Owner devices.** Each owner device is bound to one principal, and a claim of any other
  principal is refused.
- **Input.** Input that carries another principal is rejected.
- **Strangers.**
  - At most 128 connections may be open before sending a `Hello`; more are refused.
  - Each connection has 10 s from accept to `Hello`.
- **Refused peers.** A refused peer's `DaemonInfo` contains only versions. It has no host name,
  OS name or build.

### Grants (multiplayer)

- **Chain rules:**
  - A chain has at most 8 links.
  - Each link is for this daemon, and its signature verifies under the domain-separated
    context (`Grant::SIGNING_CONTEXT`; approvals use `approval-v1\0`).
  - Signatures are checked with `verify_strict`, which rejects small-order keys and
    non-canonical points.
  - The root's issuer must be byte-equal to the daemon key or to a paired owner device.
  - Every child must be signed by the holder of its parent: the parent's `bind`, or the
    device the parent was bound to when first used.
  - Every child may only narrow its parent: roles, scope, expiry and number of uses.
  - No link may be expired or revoked.
- **When it is checked.** All of this is verified when the chain is presented. On every
  message and every 0.5 s, the live check repeats expiry, revocation of any link or signer,
  and trust in the root.
- **Binding.** An unbound invite is bound to the first device that redeems it.
- **Use limits.** `max_uses` counts distinct devices. A spent single-use link is refused.
- **Revocation.** Revoking a grant also covers every chain that passes through it.
- **Knock invites.** Opening a knock invite only puts the knocker in a lobby until an owner
  answers. At most 8 knocks wait per invite, and a knock is dropped when its invite's chain
  stops being valid.
- **The grant store fails closed.** If `grants.json` cannot be read, the daemon does not start,
  so revocations and use counts are never silently forgotten (compare Teleport CVE-2025-49825
  and Tailscale TS-2025-008).
- **Role enforcement.** Every `ctl`, input, workspace, assist, artifact, stream and multiplayer
  path goes through `policy::check` (docs/DAEMON.md §6.3). A matrix test tries every guest
  role against requests from across the table: prompt, files, upload, forward, editor, lease,
  push, usage, grants, devices, audit, revoke, knocks, approval rules, split, close and new
  session.

### Parsing and denial of service

- Frames are at most 4 MiB, and the length is checked before anything is allocated.
- Decoding uses postcard with serde's cautious size hints, so a large element count cannot
  allocate past the bytes that actually arrived.
- A proptest decodes random and mangled bytes as every wire type, ticket and invite.
- The client caps zstd snapshots and history pages at 64 MiB after decompression. Guests join
  other people's daemons, so a decompression bomb would otherwise exhaust a phone's memory.
- The daemon accepts compressed data only from its owner (upgrades).


- **A leaked ticket is owner access for up to 10 minutes.**
  - Our defences: a short time to live, single use, and an alert on the other devices.
  - Not defended: a host whose only device is the one being paired, since there is no other
    device to warn.
  - App work still to do:
    - Show the host name and key fingerprint and ask for confirmation before pairing from a
      link. Today a `…://pair/` deep link pairs with no confirmation; invite links already
      open a Join sheet.
    - Show `devicePaired` in the Devices screen and in a notification, not only as a toast.
- **Pre-`Hello` limit and relays.**
  - Anyone who knows the daemon id can occupy the 128 pre-`Hello` slots, at a cost of about
    one connection per slot every 10 s, and so delay an owner's reconnect.
  - Traffic through a relay has no per-IP accounting.
  - Running our own relays with an auth token (`RelayMode::Custom`) narrows who can reach the
    daemon at all.
- **Delegation and use counts.** A delegable grant lets its holder mint as many narrower child
  invites as they like. `max_uses` limits the devices that redeem each link, not the whole
  tree. This is by design; invite delegation is off by default.
- **Driver means a shell.** The Driver role, and any session-scoped guest who can reach the
  host, can run commands as the user, including forwarding to local Unix sockets. Roles do not
  sandbox this.
- **Removal does not undo actions.** Unpairing or revoking stops access. It does not undo what
  the device or guest already did: processes they started and files they changed.
- **Metadata in tickets and links.** Tickets and invites carry addresses, which reveal the
  host's IPs to anyone who sees the link. Invite links are bearer secrets until redeemed:
  - Single-use is the default.
  - Opening a link never redeems it; redeeming takes a tap in the app.
  - Link-preview bots cannot use them, since redeeming needs an iroh client.
- **Disk access.** `daemon.key` sits in a 0700 directory but is not in the Keychain. Malware
  running as the same user can read it.
