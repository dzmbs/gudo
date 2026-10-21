# Push notifications

ARCHITECTURE D16: no accounts. One Cloudflare Worker (the **push relay**,
`services/push-relay/`) holds the APNs key and forwards **end-to-end sealed** payloads. The
relay learns an APNs token (inside a capability it issued itself), ciphertext, timing and a

```
 app ──(1) POST /v1/register {apns token, env, daemon id}──▶ relay ──▶ {cap}
 app ──(2) PushRegister {cap, X25519 key, prefs} over iroh──▶ daemon         (stores cap, key)
 daemon ── attention item unseen ≥ delay ──(3) POST /v1/push {cap, sealed, category}, signed ──▶ relay
 relay ──(4) HTTP/2, .p8 JWT, mutable-content: 1 ──▶ APNs ──▶ device: NSE decrypts, verifies
 user taps Approve ──(5) one-shot iroh connection: PushAction {token, decision, device sig} ──▶ daemon
```

## 1. Pieces

| Piece | Where | Tests |
|---|---|---|
| Formats + crypto (HPKE, signatures, tokens) | `crates/push` | `cargo test -p push` (RFC 9180 vector, shared vectors) |
| Wire messages | `crates/proto` (`PushRegister`, `PushUnregister`, `PushStatus`, `PushAction`; `Push`, `PushDecided`) | golden bytes |
| Daemon notifier | `crates/daemon/src/notifier.rs`, `[push]` in `config.toml` | `cargo test -p daemon --test it notify` |
| App side (register, decrypt, one-shot action) | `crates/client-core/src/push.rs` | via the daemon tests |
| Worker | `services/push-relay` | `npm test` (vitest in workerd via `@cloudflare/vitest-plugin`) |
| NSE decryption | `apple/Packages/PushCrypto` (CryptoKit only) | `swift test` against Rust-made vectors |

## 2. Registration

1. The app gets its APNs token (`registerForRemoteNotifications`) and creates **one X25519
   key pair per device** (`Curve25519.KeyAgreement.PrivateKey`), stored in the Keychain in an
   access group shared with the NSE and widget, accessible `AfterFirstUnlock` (the NSE runs on
   a locked phone).
2. For each paired host: `POST <relay>/v1/register`
   `{"token": "<hex>", "env": "production"|"sandbox", "daemon": "<daemon id hex>", "kind": "alert"}`
   → `{"cap": "v1.…", "expires": <unix s>}`. The capability is
   `AES-256-GCM(PUSH_CAP_KEY, {t: token, e: env, d: daemon, k: kind, x: expiry})`: stateless
   (no database), bound to one daemon, valid 180 days (`CAP_TTL_DAYS`). Registration is
   rate-limited per client IP (20/hour).
3. Over the existing connection: `Client::push_register(PushRegistration { cap, seal_key,
   relay_url, prefs, activity_cap })`. The daemon keeps it per **device** in
   `<state>/push.json` (0600). It never sees the APNs token. `PushPrefs` picks kinds
   (approvals, blocked, done, failed, long commands). Re-register when the APNs token changes,
   on each app launch (cheap) and before `expires`.

## 3. Delivery (daemon)

`notifier::run` watches the attention feed (DAEMON.md §5.8). For every new **unseen** item:

- **Debounce**: wait `push.delay` (3 s). Skip if the item became seen meanwhile (any client
  focused the pane, the blocker went away) or a newer unseen item exists for the same pane.
- **Per device**: skip if its prefs exclude the kind, or if that device is connected and
  showing a pane of this host right now (the app is in the foreground and alerts itself).
- **Seal** a `push::Notification` (JSON: daemon id, host, kind, item, pane, session, title,
  body, time, optional `action`) to the device key; body shortened if the result would not
  fit APNs' 4 KiB.
- **Sign and POST** `push::RelayRequest` to `<relay>/v1/push` with header
  `x-push-signature: base64url(Ed25519(daemon iroh key, "push-relay/v1\0" || body))`.
- **Retry** 429/5xx/network errors with exponential back-off (1 s, doubling, 5 attempts,
  `Retry-After` honoured), each attempt with a fresh `ts` and `nonce`. `410` → the device's
  registration is dropped. Other 4xx → recorded as `PushStatus.last_error`.
- `collapse` = HMAC(daemon secret, pane ‖ category), 32 hex: a newer notification for the same
  pane replaces the older one on the lock screen; the relay cannot map it to a pane.

`config.toml`:

```toml
[push]
enabled = true                         # false: nothing leaves the host
relay = "https://push.example.com"     # default: brand::PUSH_RELAY_URL
delay_ms = 3000
```

Kinds → categories: approval (agent blocked on a hook request with Allow/Deny options) →
`AGENT_APPROVAL` (Approve, Deny, Open); other blocked → `AGENT_BLOCKED` (Open); done/failed →
`AGENT_DONE`; long command → `COMMAND_DONE`. The relay sees only `approval | blocked | done |
command`.

## 4. Sealed payload format

```
sealed    = base64url( enc[32] || HPKE ciphertext )
HPKE      = RFC 9180 base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305
            info = "push-seal/v1", aad = ""          (CryptoKit: .Curve25519_SHA256_ChachaPoly)
plaintext = 0x01 || Ed25519(daemon key, "push-payload/v1\0" || json)[64] || json
```

The NSE opens it with the device key, parses the JSON, checks `daemon` is a paired host and
verifies the signature with that key (HPKE base mode alone does not authenticate the sender).
It then sets title, subtitle (host), body, **category from the payload** (never trusting the
relay's), thread (per host) and interruption level. On any failure the relay's placeholder
text stays ("Approval needed" / "An agent is waiting for you.").

Shared vectors: `crates/push/tests/vectors/push-v1.json` (generated; the Swift package keeps a
byte-identical copy, enforced by the Rust test; regenerate both with
`UPDATE_PUSH_VECTORS=1 cargo test -p push --test vectors`). They hold three notifications, a
Live Activity state, three payloads that must be rejected (wrong key, bit flip, wrong signer),
decision signatures, a signed relay request (the Worker verifies it) and RFC 9180 A.2.1.

## 5. Approve / Deny from the lock screen

An approval notification carries `action.token`: `postcard(ActionToken { daemon, device,
pane, request, approve option, deny option, item, expires }) || Ed25519(daemon,
"push-action-token/v1\0" || postcard)`. It is bound to the one device the payload was sealed
for and expires after an hour (`push.action_ttl`). The daemon verifies it with its own key, so
it keeps no token state; the agent request itself accepts only the first decision.

The app registers categories with `UNNotificationAction`s `APPROVE` and `DENY` using
`.authenticationRequired` (Face ID / passcode before the handler runs; DENY also
`.destructive`) and `OPEN` with `.foreground`. The handler (`userNotificationCenter(_:didReceive:)`,
run in the background without UI) reads the payload stored by the NSE (`PushContent.payload`),
the device's iroh key from the Keychain, the host's ticket, and calls
`client_core::push::send_action(_blocking)`: dial (direct addresses and relay from the
ticket), `Hello` with the device grant, `PushAction { token, approve, sig }` where `sig =
Ed25519(device key, "push-action/v1\0" || token || decision)`, wait for `PushDecided`, close.
checks token signature, expiry, that the connection's device is the token's device, and the
decision signature, then applies the decision as that device (`Decided.decided_by`) and marks
the item seen everywhere. A second tap gets `Conflict`/`NotFound`; another device's token
gets `Denied`.

## 6. Live Activities

One activity aggregates all agents of all hosts (04 open question 3). Channel:

- Registration with `kind: "activity"` yields a capability for the app's **push-to-start**
  token (`Activity<AgentsActivityAttributes>.pushToStartTokenUpdates`) or, once running, the
  activity's **update** token (`activity.pushTokenUpdates`); sent as `activity_cap`.
- `RelayRequest { push_type: "live_activity", event: "start"|"update"|"end", sealed, stale,
  dismiss, urgent }`. The relay sends `apns-push-type: liveactivity`, topic
  `<bundle>.push-type.liveactivity`, priority 5 (10 when `urgent`, e.g. an agent became
  blocked; priority 10 counts against the budget; use `NSSupportsLiveActivitiesFrequentUpdates`),
  payload:

  ```json
  {"aps": {"timestamp": 1760000000, "event": "update",
           "content-state": {"s": "<sealed ActivityState>", "v": 1},
           "stale-date": 1760000900, "dismissal-date": 1760003600,
           "attributes-type": "AgentsActivityAttributes", "attributes": {"v": 1},
           "alert": {"title": "Agents", "body": "Your agents are running."}}}
  ```

  (`attributes-type`, `attributes` and `alert` only with `start`.)
- Content-state cannot go through the NSE, so it stays sealed on the wire: the app's
  `ContentState` is `{ s: String, v: Int }` and the widget view decrypts `s` with PushCrypto
  (`Opened.activity()`: running / blocked / done counts and a headline per host) using the same
  Keychain group.

Daemon (`crates/daemon/src/notifier/activity.rs`, 2026-10-21): it summarises its agents (working,
needing the user, finished turns nobody has seen, one headline: the first blocker, else the first
working agent, else the last finished turn) and, after `activity_debounce` (1 s), sends each device:

- `start` to the push-to-start capability (`PushRegistration.activity_cap`) when agents become
  active and the device reports no running activity; once per busy spell (a dismissed activity is
  not forced back while the same agents work on);
- `update` to the running activity's capability when the summary changed: at once and `urgent`
  when more agents need the user, otherwise at most every `push.activity_interval_ms` (15 s);
- `end` (`dismiss` = now + 10 min) once every agent stayed idle for `activity_end_after` (2 min);
  the activity's capability is then forgotten. `stale` = now + 15 min on start and update.

A `410` forgets that capability (start or update). `push.live_activity = false` turns it off;
daemons that send it offer `DaemonFeatures::LIVE_ACTIVITY` and answer
`WorkspaceRequest::PushActivity { cap }` (the running activity's update capability, `None` when it
ended or was dismissed; needs a push registration). The update capability survives
re-registration (each launch).

App: `AgentsLiveActivity` (push builds) registers the push-to-start token
(`pushToStartTokenUpdates`) with every daemon's push registration (`HostsModel.registerPush(…,
activityStartToken:)`), and each running activity's update token (`pushTokenUpdates`) with every
connected daemon (`registerActivityToken`), `nil` when it ends; two activities started at once by
two hosts: the newer is ended. The widget (`AgentsActivity`, `NotifyKit.AgentsActivityReader`)
opens each push's sealed row, keeps the other hosts' rows (app group, dropped after 20 minutes)
and shows the sum; tapping it opens the Inbox. With push, the local per-run activity
(`AgentRunAttributes`) is not started.

Tests: `activity.rs` unit tests (start once per spell, rate limit, urgent, end),
`cargo test -p daemon --test it live_activity` (fake relay: start, token handover, urgent update,
finished, end, gone token, dismissal), the ignored `local_dev_relay_live_activity` (real Worker in
`wrangler dev` + fake APNs: well-formed `liveactivity` requests whose content state opens),
`NotifyKitTests.AgentsActivityTests` (shared vector, merging), `HostKitTests.PushRegistrationTests`.

Remaining (paid account): real push-to-start and update tokens and delivery on a device, the

## 7. Local development (no Apple account)

```sh
cd services/push-relay
npm install
npm run gen-dev-vars        # .dev.vars: throwaway P-256 "APNs" key + cap key (gitignored)
npm run fake-apns           # terminal 1: fake APNs on 127.0.0.1:8790 (GET /log)
npm run dev                 # terminal 2: wrangler dev --env dev on 127.0.0.1:8787
# terminal 3: a real daemon + client-core against them
PUSH_DEV_RELAY=http://127.0.0.1:8787 cargo test -p daemon --test it local_dev_relay -- --ignored
```

The fake APNs checks request shape, answers 410 for tokens starting with `dead` and 503 for
`busy`. A real daemon uses it with `[push] relay = "http://127.0.0.1:8787"`. `wrangler dev`
does not speak HTTP/2 to Apple; only the deployed Worker talks to real APNs.

## 8. Owner: deploy (needs Cloudflare + the paid Apple Developer account)

Apple (developer.apple.com):

1. Identifiers → the app id `dev.unnamed.app` (`apple/Brand.xcconfig`): enable **Push
   Notifications**; add an App Group / Keychain access group shared by the app, the
   Notification Service Extension and the widget.
2. Keys → **+** → enable **Apple Push Notifications service (APNs)**, environment *Sandbox &
   Production*, restrict to the app's topic if offered → download `AuthKey_<KEYID>.p8` (once).
   Note the **Key ID** and the **Team ID** (Membership).
3. Request the **Time Sensitive Notifications** capability on the app id (self-serve) for
   approvals.

Cloudflare:

4. Add the zone for the product domain; pick the relay host (`push.<domain>`) and set it in
   `crates/brand` `PUSH_RELAY_URL` and in `wrangler.jsonc` `routes`.
5. In `services/push-relay/wrangler.jsonc` set `APNS_TEAM_ID`, `APNS_KEY_ID` (`APNS_TOPIC`
   is the bundle id).
6. Secrets (never committed):

   ```sh
   cd services/push-relay && npm ci && npm test
   npx wrangler login
   npx wrangler secret put APNS_PRIVATE_KEY < AuthKey_<KEYID>.p8
   node scripts/gen-dev-vars.mjs --cap-key-only | npx wrangler secret put PUSH_CAP_KEY
   npx wrangler deploy
   curl -fsS https://push.<domain>/healthz     # → ok
   ```

   Workers Free covers 100k requests/day; Durable Objects on SQLite storage (used for rate
   limits and nonces) are available on Free; Paid is $5/month if limits are hit.
7. Rotate the cap key: `wrangler secret put PUSH_CAP_KEY_PREVIOUS` (old value), then a new
   `PUSH_CAP_KEY`; apps re-register on launch; delete the previous key after `CAP_TTL_DAYS`.
8. Debug builds get sandbox tokens: the app must send `"env": "sandbox"` for Development
   builds and `"production"` for TestFlight/App Store.

App side (2026-10-19, docs/APP-ARCHITECTURE.md §12): the `NotificationService` extension
(`NotifyKit.ServiceExtensionCore` over `PushContent.decrypt`, paired daemons and the sealing key
from the shared app group / Keychain group), the four categories with Approve / Deny / Open,
the action handler (`NotificationActionHandler`: local notifications → signed `decide`,
pushes → `sendPushAction` on a one-shot connection), registration
(`HostsModel.registerPush`: `/v1/register`, then `pushRegister`) and a local-only agent-run
Live Activity (`AgentRunAttributes`, `AgentActivityWidget`). Everything builds and runs with a
free account; APNs registration activates only with `PUSH_ENTITLEMENT = YES` and the groups in
`apple/Brand.xcconfig` (step 9).

9. App: in `apple/Brand.xcconfig` set `PUSH_ENTITLEMENT = YES`,
   `PUSH_ENTITLEMENTS_FILE = App/Push.entitlements`, `PUSH_KEYCHAIN_GROUP =
   <TEAMID>.dev.unnamed.shared`, `PUSH_APP_GROUP = group.dev.unnamed.app`; give the App and
   NotificationService targets the team (`DEVELOPMENT_TEAM`, automatic signing) and the same
   entitlements; `xcodegen`. Release builds need `aps-environment = production`.

## 9. Security notes

- The relay can drop, delay or replay-to-APNs what it receives, and sees timing and size; it
  cannot read or forge content (sender signature inside the ciphertext) or trigger actions
  (tokens are daemon-signed and bound to a device; decisions need the device key over an
  authenticated iroh connection).
- A daemon request needs the daemon's signature, a capability bound to that daemon, a
  timestamp within 5 minutes and a fresh nonce (kept per daemon in a Durable Object); 30
  burst / 300 per 15 min per daemon.
- `/v1/register` is unauthenticated (anyone who knows an APNs token could bind it to their own
  daemon). APNs tokens are not public; App Attest on registration is the hardening step if
  abuse appears.
  are not built.
