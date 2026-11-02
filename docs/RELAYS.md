# Relays: default, self-hosted, local-only

iroh dials daemons by key. Direct UDP paths (LAN, Tailscale, hole punching) come first; a relay
carries the first packets and any traffic that cannot go direct. ARCHITECTURE D16: the
default is the product's own relay, `https://relay.gudo.dev` (`brand::RELAY_URL`); power users can run their own `iroh-relay`, or
switch relays off entirely.

## 1. Modes

| Daemon `config.toml` | iroh endpoint | Pairing ticket says | App dials |
|---|---|---|---|
| *(nothing)* / `mode = "default"` | `relay.gudo.dev` + n0's address lookup | nothing extra (classic ticket) | `relay.gudo.dev` + the daemon's home relay |
| `urls = [...]` / `mode = "custom"` | only these relays, no third-party lookup | `Custom { urls, auth_token }` | only those relays |
| `mode = "local-only"` (or `hostd run --no-relay`) | no relays, no lookup | `Disabled` | direct addresses only |

```toml
# <state>/config.toml   (state dir: `gudo-hostd status`)
[relay]
mode = "custom"                         # "default" | "custom" | "local-only"
urls = ["https://relay.example.com"]    # one or more iroh-relay servers
auth_token = "long-random-token"        # if the relays use access.shared_token
ca_file = "/etc/ssl/private-ca.pem"     # only for a private CA; web roots stay trusted
```

`hostd run --no-relay` wins over the file. Restart the daemon after editing, then pair again
(`gudo-hostd pair`): the relay choice travels **in the pairing ticket**, so the phone needs no
settings. `gudo-hostd status` prints the mode.

### How the ticket carries it

`proto::TicketExtras { v, relays: TicketRelays }` is appended to the ticket's postcard bytes
after a marker byte (`0xE7`), inside the same base32 `gudo://pair/…` payload. Parsers that
predate it ignore trailing bytes, so older apps still pair (through `relay_url`, which a
custom-relay daemon sets to its home relay among its own). With default relays nothing is
appended and the ticket is byte-identical to before. Extras of a newer version are ignored.

On the app side `client_core::Client::connect*` reads the extras: if the app's own
`RelayMode` is `Disabled` (a "local only" switch in the app) that wins; then a local-only
daemon (`Disabled` in the ticket) is dialled directly; then the app's own relays
(`ConnectOptions::relay_urls`, `relay_auth_token`) replace the ticket's; otherwise the daemon's
choice is used. `ConnectOptions::relay_ca_der` adds trust roots for a private-CA relay.
`Client::set_relays` changes all of this on a running client (a new endpoint, then the usual
resume).

### In the app: Settings › Network

- **Default** follows each host's ticket.
- **Direct and Local Network Only** is `RelayMode.disabled` for every host: no relay, no
  lookup, whatever the ticket says.
- **Custom Relay** sends every host through the user's `iroh-relay` (URL checked as typed,
  `https://` assumed; optional access token kept in the Keychain). The hosts must use the same
  relay; local-only hosts stay direct.
- **Relay Certificate Authorities**: import a `.pem` (one or more certificates), `.crt`, `.cer`
  or `.der` from Files; each shows its subject and expiry and can be removed. They go into
  `relay_ca_der` for every connection.

Saved in `relay-settings.json` next to `hosts.json` (`HostKit.RelaySettings`); a change redials
open hosts at once. The pairing sheet shows which relay a pasted ticket's host will use and
whether the setting decided it.

### Local-only (LAN / Tailscale / VPN)

No relay, no address lookup, no third party at all. Works when the phone can reach one of the
daemon's direct addresses: same LAN, a Tailscale `100.x` address, or any VPN. The ticket lists
the addresses the daemon saw at pairing time; if they change (DHCP), pair again or reconnect
while on the same network. Push notifications still need the push relay (docs/PUSH.md) unless
`[push] enabled = false`.

## 2. Run your own iroh-relay on a VPS (Docker)

Needs: a VPS with a public IPv4 (and ideally IPv6), a DNS name, ports **80/tcp, 443/tcp,
7842/udp** open. 1 vCPU / 1 GB is plenty for a household; bandwidth is the cost driver

1. DNS: `A` (and `AAAA`) record `relay.example.com` → the VPS.
2. On the VPS:

   ```sh
   mkdir -p ~/iroh-relay && cd ~/iroh-relay
   # copy services/iroh-relay/{docker-compose.yml,iroh-relay.toml} from this repo here
   echo "IROH_RELAY_ACCESS_TOKEN=$(openssl rand -base64 32)" > .env && chmod 600 .env
   $EDITOR iroh-relay.toml   # hostname, contact email
   docker compose up -d      # refuses to start without the token in .env
   docker compose logs -f    # watch the Let's Encrypt certificate arrive
   curl -fsS https://relay.example.com/healthz
   ```

   The image tag must match the iroh version the app and daemon use (`iroh = "1.3.0"` in
   `Cargo.toml` → `n0computer/iroh-relay:v1.3.0`); bump them together. For production, pin
   the digest too (`image: n0computer/iroh-relay:v1.3.0@sha256:…`, from `docker pull`).

   The container runs as an unprivileged user with no capabilities, a read-only root
   filesystem (only the certificate volume is writable), `no-new-privileges`, and memory,
   CPU, process and log-size limits; a one-shot `relay-data-owner` service hands the volume to
   that user. Metrics listen on the container's loopback only. Publish nothing but 80, 443/tcp
   and 7842/udp, and keep the host firewall closed otherwise.
3. On each host, `<state>/config.toml`:

   ```toml
   [relay]
   urls = ["https://relay.example.com"]
   auth_token = "<token>"
   ```

   then restart the daemon (`gudo-hostd service install` re-installs and restarts it, or
   restart the service) and `gudo-hostd pair` to give the phone a ticket with the relay.
4. Several regions: run one relay per region and list them all in `urls`; iroh picks the
   lowest-latency one as the daemon's home relay.

Access control options (`iroh-relay.toml` `access`): `"everyone"` (open relay; not
recommended), `allowlist = [endpoint ids]`, `denylist`, `http` (a callback URL answering `true`)
and `shared_token` (above). The token is sent as `Authorization: Bearer` by both the daemon and
the app (`RelayMap::with_auth_token`). Never run `"everyone"` on the internet: an open relay
is a free, anonymous bandwidth proxy for anyone. The token travels in pairing tickets, so
every device you pair can use the relay; rotate it (new `.env`, daemon config, pair
again) if a ticket leaks. Access control covers relaying only; QUIC address discovery on UDP
7842 answers anyone (it only reports the caller's own address).

Without Docker: `cargo install iroh-relay --version 1.3.0 --features server` and run
`iroh-relay --config-path iroh-relay.toml` under systemd, with your token in
`access.shared_token` (the shipped `[""]` makes the relay refuse to start) or in
`IROH_RELAY_ACCESS_TOKEN`. For a quick LAN experiment,
`iroh-relay --dev` serves plain HTTP on port 3340 (use `urls = ["http://host:3340"]`).

## 3. Tests

`cargo test -p daemon --test it relays`:

- `daemon_and_client_connect_through_a_self_hosted_relay` — spawns an `iroh-relay` server in
  process (self-signed certificate for 127.0.0.1), starts a daemon with `RelayMode::Custom` and
  the certificate as `ca_files`, mints a pairing link, **strips the direct addresses** from
  the ticket, and connects a default-mode client with the certificate in
  `ConnectOptions::relay_ca_der`; the client attaches and round-trips a shell command, which is
  only possible through the relay.
- `local_only_daemons_hand_out_direct_tickets` — a relay-less daemon's link carries
  `TicketRelays::Disabled` and a default-mode client follows it and connects directly.
- `relay_settings_come_from_config_toml` — parsing, validation and the `--no-relay`
  precedence.

`cargo test -p proto --test golden ticket_extras` freezes the extension bytes and checks old
parsers still read extended tickets.

## 4. Not done

- The default relay `relay.gudo.dev` must be running before release: until it is, devices on
  different networks reach a default-mode daemon only over direct paths.
- A daemon whose home relay changes while no client is connected relies on the app redialling
- No per-host override of the Network setting: it applies to every host.
- The private-CA path is tested in Rust against an in-process relay; the app's UI test imports
  a CA and connects directly (no relay runs in the simulator test).
- The Docker setup was written against the iroh-relay 1.3.0 config schema but not run on a
  real VPS here.
