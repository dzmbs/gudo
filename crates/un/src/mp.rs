//! Multiplayer subcommands: invites, who is here, take control, prompts, grants, revocation
//! and the audit log.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use client_core::proto::{
    AuditKind, DeviceId, GrantId, LeaseOutcome, MpResponse, PaneId, PresenceState, PrincipalId,
    RevokeTarget, Roles, Scope, SessionId, TabId, UnixMillis,
};
use client_core::{GrantSpec, MultiplayerEvent, MultiplayerEventQueue, now_millis};

use crate::Conn;

#[derive(Subcommand)]
pub(crate) enum MpCmd {
    /// Create an invite link (and QR code). An owner signs a new grant; a guest whose grant
    /// allows delegation signs a narrower one.
    Invite {
        /// Roles, joined by `+`: viewer, prompter, driver, approver, owner.
        #[arg(long, default_value = "viewer")]
        role: String,
        /// `daemon`, `session[:ID]` (default: the attached session), `tab[:ID]`,
        /// `pane[:ID]` (default: the focused one).
        #[arg(long, default_value = "session")]
        scope: String,
        /// Lifetime: `30m`, `24h`, `7d`, or `never`.
        #[arg(long, default_value = "24h")]
        ttl: String,
        /// How many devices may redeem it (`0`: unlimited).
        #[arg(long, default_value_t = 1)]
        uses: u32,
        /// Who it is for, shown to the others.
        #[arg(long, default_value = "")]
        name: String,
        /// Let the guest share narrower invites of their own.
        #[arg(long)]
        delegate: bool,
        /// Bind to this guest device key (hex) instead of the first device to use it.
        #[arg(long)]
        bind: Option<String>,
        /// Print only the link.
        #[arg(long)]
        no_qr: bool,
    },
    /// Who is connected, their roles and what they look at.
    Who {
        /// Keep printing changes.
        #[arg(long)]
        watch: bool,
    },
    /// Ask for the input lease on a pane (default: focused).
    TakeControl {
        #[arg(long)]
        pane: Option<u64>,
        /// Take it now (owner).
        #[arg(long)]
        force: bool,
        /// Wait for the holder to answer or go idle.
        #[arg(long)]
        wait: bool,
    },
    /// Give up the input lease on a pane.
    ReleaseControl {
        #[arg(long)]
        pane: Option<u64>,
    },
    /// Send a prompt to an agent pane through the composer (the prompter's only input).
    Prompt {
        text: String,
        #[arg(long)]
        pane: Option<u64>,
        /// Paste without pressing Enter.
        #[arg(long)]
        no_submit: bool,
    },
    /// Grants and devices this daemon knows (owner).
    Grants {
        /// List devices instead.
        #[arg(long)]
        devices: bool,
    },
    /// Revoke a grant (hex id or prefix), `--device KEY` or `--principal ID`; disconnects at
    /// once (owner).
    Revoke {
        grant: Option<String>,
        #[arg(long, conflicts_with_all = ["grant", "principal"])]
        device: Option<String>,
        #[arg(long, conflicts_with_all = ["grant", "device"])]
        principal: Option<String>,
    },
    /// The audit log (owner).
    Audit {
        #[arg(long, default_value_t = 50)]
        limit: u32,
        /// Records after this sequence number.
        #[arg(long)]
        after: Option<u64>,
    },
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex<const N: usize>(s: &str) -> Result<[u8; N]> {
    let s = s.trim();
    if s.len() != N * 2 {
        bail!("expected {} hex digits", N * 2);
    }
    let mut out = [0; N];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).context("not hex")?;
    }
    Ok(out)
}

fn parse_ttl(s: &str) -> Result<Option<Duration>> {
    if s == "never" {
        return Ok(None);
    }
    let (num, unit) = s.split_at(s.len().saturating_sub(1));
    let n: u64 = num.parse().with_context(|| format!("bad ttl {s:?}"))?;
    let secs = match unit {
        "s" => n,
        "m" => n * 60,
        "h" => n * 3600,
        "d" => n * 86_400,
        _ => bail!("ttl unit must be s, m, h or d"),
    };
    Ok(Some(Duration::from_secs(secs)))
}

fn parse_scope(conn: &Conn, s: &str) -> Result<Scope> {
    let (kind, id) = match s.split_once(':') {
        Some((k, id)) => (k, Some(id.parse::<u64>().context("bad scope id")?)),
        None => (s, None),
    };
    Ok(match kind {
        "daemon" => Scope::Daemon,
        "session" => Scope::Session(id.map_or(conn.layout().session_id, SessionId)),
        "tab" => Scope::Tab(id.map_or(conn.tab()?.tab_id, TabId)),
        "pane" => Scope::Pane(id.map_or(conn.tab()?.focused, PaneId)),
        other => bail!("unknown scope {other:?}"),
    })
}

fn when(t: Option<UnixMillis>) -> String {
    match t {
        None => "never".into(),
        Some(t) => {
            let now = now_millis().0 as i64;
            let secs = (t.0 as i64 - now) / 1000;
            if secs <= 0 {
                "expired".into()
            } else if secs < 3600 {
                format!("in {}m", secs / 60)
            } else if secs < 86_400 {
                format!("in {}h", secs / 3600)
            } else {
                format!("in {}d", secs / 86_400)
            }
        }
    }
}

/// Prints the invite as a QR code (Unicode half blocks, works over SSH) and as a link.
fn print_invite(link: &str, qr: bool) {
    if qr {
        // Upper case lets the QR use alphanumeric mode; parsing ignores case.
        match qrcode::QrCode::new(link.to_ascii_uppercase().as_bytes()) {
            Ok(code) => {
                let qr = code
                    .render::<qrcode::render::unicode::Dense1x2>()
                    .dark_color(qrcode::render::unicode::Dense1x2::Light)
                    .light_color(qrcode::render::unicode::Dense1x2::Dark)
                    .quiet_zone(true)
                    .build();
                println!("{qr}");
            }
            Err(e) => eprintln!("(no QR code: {e})"),
        }
    }
    println!("{link}");
}

fn print_participants(conn: &Conn, list: &[client_core::proto::Participant]) {
    let me = conn.client.me().map(|m| m.actor.device);
    for p in list {
        let state = match p.state {
            PresenceState::Active => "active",
            PresenceState::Idle => "idle",
            PresenceState::Away => "away",
        };
        let focus = p.focus.map_or("-".into(), |f| format!("pane {f}"));
        let typing = if p.typing { " typing…" } else { "" };
        let you = if Some(p.actor.device) == me {
            " (you)"
        } else {
            ""
        };
        println!(
            "{:<12} {:<22} {:<14} {:<7} {focus}{typing}{you}",
            p.name,
            p.roles.names(),
            p.scope.to_string(),
            state
        );
    }
}

pub(crate) async fn run(conn: &mut Conn, cmd: MpCmd) -> Result<()> {
    match cmd {
        MpCmd::Invite {
            role,
            scope,
            ttl,
            uses,
            name,
            delegate,
            bind,
            no_qr,
        } => {
            let roles: Roles = role.parse().map_err(anyhow::Error::msg)?;
            let mut spec = GrantSpec::new(roles, parse_scope(conn, &scope)?);
            spec.expires =
                parse_ttl(&ttl)?.map(|d| UnixMillis(now_millis().0 + d.as_millis() as u64));
            spec.max_uses = (uses > 0).then_some(uses);
            spec.label = name;
            spec.delegate = delegate;
            spec.bind = bind.as_deref().map(unhex::<32>).transpose()?.map(DeviceId);
            let inviter = conn.client.me().map_or_else(|| "owner".into(), |m| m.name);
            let invite = conn.client.create_invite(spec.clone(), inviter).await?;
            print_invite(&invite.to_string(), !no_qr);
            eprintln!(
                "grant {}: {} on {}, expires {}, uses {}",
                hex(&invite.chain.grant_id().0[..4]),
                roles.names(),
                spec.scope,
                when(spec.expires),
                spec.max_uses.map_or("unlimited".into(), |u| u.to_string()),
            );
        }
        MpCmd::Who { watch } => {
            let list = conn.client.participants().await?;
            print_participants(conn, &list);
            if watch {
                let (listener, mut events) = MultiplayerEventQueue::channel();
                conn.client.set_multiplayer_listener(listener);
                while let Some(event) = events.recv().await {
                    match event {
                        MultiplayerEvent::Participants { participants } => {
                            println!("--");
                            print_participants(conn, &participants);
                        }
                        MultiplayerEvent::Presence { presence } if presence.typing => {
                            println!(
                                "{:?} typing in {:?}",
                                presence.actor.principal, presence.focus
                            );
                        }
                        MultiplayerEvent::Lease { lease } => println!(
                            "pane {}: {}",
                            lease.pane_id,
                            lease
                                .holder
                                .map_or("free".into(), |h| format!("driven by {}", hex(&h.0[..4])))
                        ),
                        MultiplayerEvent::Revoked => bail!("access revoked"),
                        _ => {}
                    }
                }
            }
        }
        MpCmd::TakeControl { pane, force, wait } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            let (listener, mut events) = MultiplayerEventQueue::channel();
            conn.client.set_multiplayer_listener(listener);
            let me = conn.client.me().map(|m| m.actor.principal);
            match conn.client.take_control(pane_id, force).await? {
                LeaseOutcome::Granted(_) => println!("you have control of pane {pane_id}"),
                LeaseOutcome::Kept(_) => bail!("the holder kept control"),
                LeaseOutcome::Pending { holder } => {
                    println!(
                        "asked {} for pane {pane_id}; it moves when they give it or go idle",
                        hex(&holder.0[..4])
                    );
                    if wait {
                        while let Some(event) = events.recv().await {
                            if let MultiplayerEvent::Lease { lease } = event
                                && lease.pane_id == pane_id
                            {
                                if lease.holder == me {
                                    println!("you have control of pane {pane_id}");
                                    break;
                                }
                                if lease.holder == Some(holder) {
                                    bail!("the holder kept control");
                                }
                            }
                        }
                    }
                }
            }
        }
        MpCmd::ReleaseControl { pane } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            conn.client.release_control(pane_id).await?;
            println!("released pane {pane_id}");
        }
        MpCmd::Prompt {
            text,
            pane,
            no_submit,
        } => {
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            let n = conn.client.prompt(pane_id, text, !no_submit).await?;
            println!("sent {n} characters to pane {pane_id}");
        }
        MpCmd::Grants { devices } => {
            if devices {
                for d in conn.client.list_devices().await? {
                    println!(
                        "{}  {:<6} {:<12} {}{}{}",
                        hex(&d.device.0),
                        format!("{:?}", d.kind).to_lowercase(),
                        d.name,
                        d.grant_id
                            .map_or(String::new(), |g| format!("grant {} ", hex(&g.0[..4]))),
                        if d.connected > 0 {
                            format!("connected×{}", d.connected)
                        } else {
                            String::new()
                        },
                        if d.revoked { " REVOKED" } else { "" },
                    );
                }
            } else {
                for g in conn.client.list_grants().await? {
                    let leaf = &g.grant;
                    println!(
                        "{}  {:<10} {:<20} {:<12} expires {:<8} uses {}/{}{}{}{}",
                        hex(&leaf.grant_id.0),
                        if leaf.label.is_empty() {
                            "-"
                        } else {
                            &leaf.label
                        },
                        leaf.roles.names(),
                        leaf.scope.to_string(),
                        when(leaf.expires),
                        g.bound.len(),
                        leaf.max_uses.map_or("∞".into(), |u| u.to_string()),
                        g.parent
                            .map_or(String::new(), |p| format!(" from {}", hex(&p.0[..4]))),
                        if leaf.delegate { " delegable" } else { "" },
                        if g.revoked { " REVOKED" } else { "" },
                    );
                }
            }
        }
        MpCmd::Revoke {
            grant,
            device,
            principal,
        } => {
            let target = if let Some(d) = device {
                RevokeTarget::Device(DeviceId(unhex(&d)?))
            } else if let Some(p) = principal {
                RevokeTarget::Principal(PrincipalId(unhex(&p)?))
            } else {
                let prefix = grant.context("give a grant id, --device or --principal")?;
                let grants = conn.client.list_grants().await?;
                let matches: Vec<GrantId> = grants
                    .iter()
                    .map(|g| g.grant.grant_id)
                    .filter(|id| hex(&id.0).starts_with(&prefix.to_ascii_lowercase()))
                    .collect();
                match matches.as_slice() {
                    [one] => RevokeTarget::Grant(*one),
                    [] => RevokeTarget::Grant(GrantId(unhex(&prefix)?)),
                    _ => bail!("{prefix:?} matches {} grants", matches.len()),
                }
            };
            if let MpResponse::Revoked {
                grants,
                devices,
                disconnected,
            } = conn.client.revoke(target).await?
            {
                println!(
                    "revoked {} grant(s), {} device(s); {disconnected} connection(s) closed",
                    grants.len(),
                    devices.len()
                );
            }
        }
        MpCmd::Audit { limit, after } => {
            let page = conn.client.audit(after, limit).await?;
            for r in &page.records {
                let who = r.actor.map_or("-".into(), |a| hex(&a.device.0[..4]));
                let pane = r.pane_id.map_or(String::new(), |p| format!(" pane {p}"));
                let signed = if r.kind == AuditKind::Approval && r.approval.is_some() {
                    " [signed]"
                } else {
                    ""
                };
                println!(
                    "{:>5} {} {:<15} {who}{pane} {}{signed}",
                    r.seq,
                    r.at.0,
                    format!("{:?}", r.kind),
                    r.detail
                );
            }
            println!(
                "{} records; hash chain and signatures {}",
                page.total,
                if page.chain_ok { "verified" } else { "BROKEN" }
            );
        }
    }
    Ok(())
}
