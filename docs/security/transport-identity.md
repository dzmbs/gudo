# Transport, identity, pairing and multiplayer

## Assets

- **The daemon key** (`daemon.key`): it identifies the host. Anyone holding it can pose as the
  host to paired devices.
- **The owner allowlist** (`devices.json`): every device on it is a full owner, with a shell as
  the user.
- **Pairing secrets** (`pairing.json`, the `gudo://pair/…` ticket and QR code): one secret
  makes one new owner device.
- **Grant chains and invite links** (`grants.json`, `gudo://join/…`): each is access for a
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
- The ALPN is `gudo/1`. There is no weaker protocol version to downgrade to.
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
  `ServerCtl::DevicePaired` with the new device's name (it has 3 s to say it) and time. The app
  shows a toast and a time-sensitive notification, "New device paired: <name>", that opens the
  host's Devices screen in Settings. This is the defence against Signal- and WhatsApp-style
  linked-device phishing. Each pairing is also recorded in the audit log. The name is chosen by
  the new device, so it can lie; the time and the alert itself cannot be suppressed by it.
- **Pairing links ask first.** A `…://pair/…` link only opens the Add Host sheet, which shows
  the host and asks before pairing (`LinkSecurityTests`).
- **Pairing from a paired device.** An owner device may ask the daemon for a ticket over its
  connection (`MpRequest::PairingTicket`, "Pair a Device" in the apps). The daemon mints it
  through the same path as `hostd pair`, so the secret, expiry and single use are the same.
  Only paired owner devices may ask; a guest is refused even with every role, since a ticket
  makes its holder an owner (`tests/it/devices.rs`). The app shows it as a QR code with a
  countdown, copies the link as a concealed, expiring clipboard item, and never logs it
  (`PairingCode`'s `Debug` leaves the link out). The new device is announced as above.
- **Names.** The owner can rename a paired device (`MpRequest::RenameDevice`, `hostd rename`);
  the name is a label for people only and changes no access. Names are trimmed, stripped of
  control characters and capped at 64 characters.

### Device lifecycle (lost phone)

The model is Apple's and Signal's device list: removing a device signs it out and cancels
everything it created, for good; it can come back only through a new pairing code the owner
makes, and then without its old invites.

- **In the app:** Settings → Devices (per host), or Access → Devices → Remove
  (`Revoke(Device)`). This closes the device's connections at once. Its later connection
  attempts on the old pairing are refused with `Revoked`.
- **On the host:**
  - `gudo devices` (or `gudo-hostd devices`) lists the owner devices; in a terminal it is a
    full-screen list that removes one after asking.
  - `gudo-hostd unpair <key prefix>` removes one.
  - The daemon re-reads `devices.json` whenever the file changes, so removal takes effect
    within 0.5 s without a restart.
- **Guests the device invited.** Removing an owner device in either way also cuts off the guests
  whose invites that device signed:
  - Every live check confirms that the chain's root is still trusted and that no signer has
    been revoked.
  - A thief therefore cannot keep access by inviting their own second key before the phone
    is removed.
- **Removal times, not a block list.** Every removal is recorded with its time: owner devices
  in `unpaired.json` (written with `devices.json`, under its lock, by the daemon and by
  `hostd unpair`), guests in `grants.json`. A chain counts only if its root was signed after
  the removal of every device in it (signer, holder or presenter). Only the root's time is
  used: roots come from owner devices or the daemon, while a guest could date its own links
  freely. So a removed device's old invites stay void even if it pairs again, and nothing
  needs to be unblocked by hand.
- **Coming back.** An owner device returns only with a fresh pairing ticket (the client falls
  back to the ticket's secret when its device grant is refused as revoked). A revoked guest
  returns only through an invite whose root was signed after the revocation, by an owner, the
  daemon (a knock admission), or a delegate whose own grant is newer.
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
- **Strangers.** Connections before their `Hello` are counted in two pools, overall and per
  source (an IPv4 address, IPv4-mapped IPv6 included, or an IPv6 /64):
  - in the QUIC handshake, key not yet known: 1024 overall, 32 per source;
  - past the handshake with a key the daemon does not trust: 128 overall, 16 per source.
  - Each connection has 10 s for the handshake and 10 s more for its `Hello`.
- **Trusted devices skip the strangers' pool.** The TLS handshake proves the client's key
  before the `Hello`, and a relay names it even before the handshake. A paired owner device,
  or a guest bound to a grant it was not removed from since, is not counted, so strangers
  filling the pool cannot lock the owner out.
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
- **The grant store fails closed for guests, not for the owner.** If `grants.json` cannot be
  read, the daemon still starts (refusing to start would lock the owner out of a remote
  machine). The file is moved aside as `grants.json.unreadable-<time>`, never overwritten,
  and every chain signed before that moment is void, since which were revoked or used up is
  unknown (compare Teleport CVE-2025-49825 and Tailscale TS-2025-008). Owner devices work
  normally, and new invites work. Owners are told: an error in the log, an audit record, and
  `ServerCtl::HostAlert` on every owner connection, which the app shows as a banner on the
  Devices screen and once as a notification. If the file cannot even be moved, the new state
  is kept in memory only, so the damaged file is left as it is.
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

## Residual risk and decisions

- **A leaked ticket is owner access for up to 10 minutes.**
  - Our defences: a short time to live, single use, and an alert on the other devices.
  - Not defended: a host whose only device is the one being paired, since there is no other
    device to warn.
  - A pairing notification arrives only on owner devices that are connected (or connect
    later and list devices). There is no push for it yet.
- **Pre-`Hello` limits.**
  - Trusted devices are not counted, but a direct connection from one still needs a
    handshake slot. An attacker with many addresses (32+ IPv4 hosts or IPv6 /64s) holding
    stalled handshakes can fill the handshake pool and delay a direct reconnect; through a
    relay a trusted device skips it.
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

## Validation

Each attack runs against a real daemon in `crates/daemon/tests/it`
unless noted, and each fix was mutation-checked: the guarded code was disabled and the test
was confirmed to fail.

| Attack | Test |
|---|---|
| Pairing secret raced by six devices; replay after use | `redteam::a_raced_pairing_ticket_pairs_one_device` |
| Expired secret; wrong guesses cause no disk write | `identity::tests::expired_pairing_secrets_are_refused`, `wrong_pairing_secrets_cost_no_write` (unit) |
| Removed owner device reconnecting on its old pairing | `access::a_removed_device_cannot_reconnect_on_its_old_pairing` |
| Re-paired device's old invites (app removal, CLI unpair) | `access::a_removed_device_returns_only_by_a_new_ticket_and_without_its_invites`, `access::re_pairing_after_cli_unpair_does_not_revive_old_invites` |
| Guest chain whose signer was unpaired or revoked | `security::unpairing_from_the_cli_closes_the_device_and_its_invites`, `security::revoking_an_owner_device_closes_the_guests_it_invited` |
| Revoked guest reusing a multi-use link | `access::a_revoked_guest_returns_only_by_a_newer_invite` |
| Delegate forward-dating its child link before removal | `props::removal_voids_older_chains_only` (unit) |
| Chain rooted at a stranger's key | `redteam::a_chain_rooted_at_a_stranger_key_is_refused` |
| Small-order key; non-canonical `S`; wrong-length signatures | `grants::tests::small_order_keys_prove_nothing`, `props::non_canonical_signatures_are_refused` (unit) |
| Single-use invite raced by six devices | `redteam::a_raced_single_use_invite_admits_one_device` |
| Invite used after expiry; guest inside at expiry | `redteam::an_expired_invite_admits_nobody_and_ends_its_sessions` |
| Knock spam (12 knocks on one link) | `redteam::knock_spam_is_capped_per_invite` |
| Silent connections; strangers filling the pre-`Hello` pool | `security::a_connection_that_never_says_hello_is_closed`, `access::a_paired_device_connects_while_strangers_fill_the_pre_hello_slots`, `preauth::tests::*` (unit, per-address and IPv4-mapped/IPv6 /64 accounting) |
| Damaged `grants.json` | `access::a_damaged_grant_store_fails_closed_for_guests_only` |
| Guest roles on `ctl`, workspace, bulk (upload), forwards and layout | `security::each_guest_role_gets_exactly_what_the_table_allows` |
| Guest roles typing raw input (`input` stream) | `redteam::only_drivers_type_into_a_pane` |
| zstd bomb / huge declared length from a hostile daemon | `client-core conn::tests::inflating_is_bounded` (unit) |
| Random and mangled bytes as every wire type, ticket and invite | `proto/tests/decode_untrusted.rs` (proptest) |

Checked and not changed:

- **Mixed-order keys** (an honest key plus a torsion point) are accepted as device keys. That
  is not a forgery: whoever holds such a key holds a key, and fresh keys are free anyway.
  Small-order keys, which nobody holds, are refused.
- **The daemon inflates nothing a guest sends.** The only decompression on the daemon is the
  owner's upgrade upload. On the client the only decompression of daemon data is snapshots
  and history pages, both bounded.
- **TLS with a small-order client key** cannot be produced in a test (no secret key exists for
  one). The handshake check (`grants::is_strong_key`) is covered by the unit test only.
