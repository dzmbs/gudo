//! Multiplayer subcommands: invites, who is here, take control, prompts, grants, revocation
//! and the audit log.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::Subcommand;
use client_core::proto::{
    Admit, ApprovalMode, ApprovalPolicy, AuditKind, DeviceClass, DeviceId, Draft, DraftSource,
    GrantId, History, InviteTerms, KnockId, KnockUpdate, LeaseOutcome, MpResponse, PaneId, Peer,
    PresenceState, PrincipalId, RequestId, RevokeTarget, Risk, Roles, Scope, SessionId, TabId,
    UnixMillis,
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
        /// Joining asks you first (`gudo knocks`, `gudo admit`, `gudo deny`).
        #[arg(long)]
        knock: bool,
        /// Scrollback the guest sees: `full` or `since-join`.
        #[arg(long, default_value = "full")]
        history: String,
        /// Who invites, shown on the join card (default: this connection's name).
        #[arg(long)]
        from: Option<String>,
    },
    /// Knocks waiting for you (owner).
    Knocks {
        /// Keep printing knocks as they come and go.
        #[arg(long)]
        watch: bool,
    },
    /// Let a knock in (owner).
    Admit {
        /// The knock's number from `gudo knocks`.
        knock: u64,
        /// Roles, joined by `+`.
        #[arg(long, default_value = "viewer")]
        role: String,
        /// Scrollback they see: `full` or `since-join`.
        #[arg(long, default_value = "since-join")]
        history: String,
        /// How long their access lasts (default 7 days).
        #[arg(long)]
        ttl: Option<String>,
    },
    /// Turn a knock away (owner).
    Deny {
        /// The knock's number from `gudo knocks`.
        knock: u64,
    },
    /// Show or set the attached session's approval rules (setting: owner).
    Policy {
        /// `any`, `owner-only`, `two-person` or `claim`.
        #[arg(long)]
        mode: Option<String>,
        /// The riskiest call approvers may allow: `read-only`, `edits` or `any`.
        #[arg(long)]
        max_risk: Option<String>,
    },
    /// Claim an open approval request so only you answer it (or `--release`).
    Claim {
        /// The request id.
        request: u64,
        #[arg(long)]
        release: bool,
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
    /// Type a draft into a pane's composer, a character at a time, live for everyone in the
    /// session (never sent to the pane), then hold it there.
    Draft {
        text: String,
        #[arg(long)]
        pane: Option<u64>,
        /// Characters per second.
        #[arg(long, default_value_t = 12.0)]
        cps: f64,
        /// Then wait until someone follows you, and move to this pane.
        #[arg(long)]
        then_focus: Option<u64>,
        /// Seconds to stay afterwards.
        #[arg(long, default_value_t = 30)]
        hold: u64,
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

fn parse_history(s: &str) -> Result<History> {
    match s {
        "full" => Ok(History::Full),
        "since-join" | "since_join" => Ok(History::SinceJoin),
        other => bail!("history is `full` or `since-join`, not {other:?}"),
    }
}

fn parse_mode(s: &str) -> Result<ApprovalMode> {
    Ok(match s {
        "any" | "any-approver" => ApprovalMode::AnyApprover,
        "owner-only" | "owner_only" => ApprovalMode::OwnerOnly,
        "two-person" | "two_person" => ApprovalMode::TwoPerson,
        "claim" => ApprovalMode::Claim,
        other => bail!("mode is any, owner-only, two-person or claim, not {other:?}"),
    })
}

fn parse_risk(s: &str) -> Result<Risk> {
    Ok(match s {
        "read-only" | "read_only" => Risk::ReadOnly,
        "edits" => Risk::Edits,
        "any" => Risk::Any,
        other => bail!("risk is read-only, edits or any, not {other:?}"),
    })
}

fn print_policy(policy: ApprovalPolicy) {
    let mode = match policy.mode {
        ApprovalMode::AnyApprover => "any approver",
        ApprovalMode::OwnerOnly => "owner only",
        ApprovalMode::TwoPerson => "two people for commands",
        ApprovalMode::Claim => "claim before answering",
    };
    println!(
        "approvals: {mode}; approvers may allow up to {}",
        policy.max_risk
    );
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
            knock,
            history,
            from,
        } => {
            let terms = InviteTerms {
                knock,
                history: parse_history(&history)?,
            };
            let roles: Roles = role.parse().map_err(anyhow::Error::msg)?;
            let mut spec = GrantSpec::new(roles, parse_scope(conn, &scope)?);
            spec.expires =
                parse_ttl(&ttl)?.map(|d| UnixMillis(now_millis().0 + d.as_millis() as u64));
            spec.max_uses = (uses > 0).then_some(uses);
            spec.label = name;
            spec.delegate = delegate;
            spec.bind = bind.as_deref().map(unhex::<32>).transpose()?.map(DeviceId);
            let inviter =
                from.unwrap_or_else(|| conn.client.me().map_or_else(|| "owner".into(), |m| m.name));
            let invite = conn
                .client
                .create_invite_with_terms(spec.clone(), inviter, terms)
                .await?;
            print_invite(&invite.to_string_with_terms(terms), !no_qr);
            eprintln!(
                "grant {}: {} on {}, expires {}, uses {}",
                hex(&invite.chain.grant_id().0[..4]),
                roles.names(),
                spec.scope,
                when(spec.expires),
                spec.max_uses.map_or("unlimited".into(), |u| u.to_string()),
            );
        }
        MpCmd::Knocks { watch } => {
            let print = |k: &client_core::proto::Knock| {
                println!(
                    "#{:<4} {:<16} wants {} on {}",
                    k.knock_id,
                    k.name,
                    k.roles.names(),
                    k.scope
                );
            };
            let (listener, mut events) = MultiplayerEventQueue::channel();
            conn.client.set_multiplayer_listener(listener);
            let knocks = conn.client.knocks().await?;
            if knocks.is_empty() && !watch {
                println!("nobody is knocking");
            }
            knocks.iter().for_each(print);
            if watch {
                while let Some(event) = events.recv().await {
                    match event {
                        MultiplayerEvent::Knock {
                            update: KnockUpdate::Added(k),
                        } => print(&k),
                        MultiplayerEvent::Knock {
                            update:
                                KnockUpdate::Gone {
                                    knock_id, outcome, ..
                                },
                        } => println!("#{knock_id} {outcome:?}"),
                        MultiplayerEvent::Revoked => bail!("access revoked"),
                        _ => {}
                    }
                }
            }
        }
        MpCmd::Admit {
            knock,
            role,
            history,
            ttl,
        } => {
            let roles: Roles = role.parse().map_err(anyhow::Error::msg)?;
            let expires = ttl
                .as_deref()
                .map(parse_ttl)
                .transpose()?
                .flatten()
                .map(|d| UnixMillis(now_millis().0 + d.as_millis() as u64));
            let admit = Admit {
                roles,
                history: parse_history(&history)?,
                expires,
            };
            let info = conn
                .client
                .answer_knock(KnockId(knock), Some(admit))
                .await?;
            match info {
                Some(g) => println!(
                    "let {} in as {} (grant {}, expires {})",
                    g.grant.label,
                    roles.names(),
                    hex(&g.grant.grant_id.0[..4]),
                    when(g.grant.expires)
                ),
                None => println!("let #{knock} in"),
            }
        }
        MpCmd::Deny { knock } => {
            conn.client.answer_knock(KnockId(knock), None).await?;
            println!("turned #{knock} away");
        }
        MpCmd::Policy { mode, max_risk } => {
            let session = conn.layout().session_id;
            let mut policy = conn.client.approval_policy(session).await?;
            if mode.is_none() && max_risk.is_none() {
                print_policy(policy);
                return Ok(());
            }
            if let Some(mode) = mode {
                policy.mode = parse_mode(&mode)?;
            }
            if let Some(risk) = max_risk {
                policy.max_risk = parse_risk(&risk)?;
            }
            print_policy(conn.client.set_approval_policy(session, policy).await?);
        }
        MpCmd::Claim { request, release } => {
            let status = conn.client.claim(RequestId(request), !release).await?;
            match status.claimed_by {
                Some(c) => println!("request {request} claimed by {}", c.name),
                None => println!("request {request} is unclaimed"),
            }
        }
        MpCmd::Who { watch } => {
            let list = conn.client.participants().await?;
            if conn.json {
                let me = conn.client.me().map(|m| m.actor.device);
                let participants = list
                    .iter()
                    .map(|p| crate::json::Person::new(p, me))
                    .collect();
                return crate::json::print("who", &crate::json::Who { participants });
            }
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
                        MultiplayerEvent::Decided { decided } => {
                            let by = conn
                                .client
                                .participant_list()
                                .into_iter()
                                .find(|p| p.actor == decided.decided_by)
                                .map_or_else(|| hex(&decided.decided_by.device.0[..4]), |p| p.name);
                            println!(
                                "request {} in pane {} decided by {by}",
                                decided.request_id, decided.pane_id
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
        MpCmd::Draft {
            text,
            pane,
            cps,
            then_focus,
            hold,
        } => {
            if !conn.client.has_live_presence() {
                bail!("the host's helper is too old for live drafts; update it");
            }
            let pane_id = pane.map_or(conn.tab()?.focused, PaneId);
            conn.client.set_device_class(DeviceClass::Terminal);
            conn.client.set_view(Some(pane_id), vec![pane_id]);
            let pause = Duration::from_secs_f64(1.0 / cps.max(1.0));
            let me = conn.client.me().map(|m| m.actor.principal);
            let follower = || -> Option<Peer> {
                conn.client
                    .peers()
                    .1
                    .into_iter()
                    .find(|p| me.is_some() && p.following == me)
            };
            // With --then-focus, type it again and again until someone follows.
            'typing: loop {
                let mut typed = String::new();
                for c in text.chars() {
                    typed.push(c);
                    conn.client.set_draft(Some(Draft {
                        pane_id,
                        source: DraftSource::Composer,
                        text: typed.clone(),
                        caret: typed.chars().count() as u32,
                    }));
                    tokio::time::sleep(pause).await;
                }
                println!(
                    "drafted {} characters in pane {pane_id}",
                    typed.chars().count()
                );
                if then_focus.is_none() {
                    break;
                }
                for _ in 0..40 {
                    if follower().is_some() {
                        break 'typing;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
            if let Some(next) = then_focus.map(PaneId) {
                let name = follower().map(|p| p.name).unwrap_or_default();
                println!("followed by {name}");
                conn.client.set_view(Some(next), vec![next]);
                println!("moved to pane {next}");
                for _ in 0..300 {
                    if follower().is_some_and(|p| p.focus == Some(next)) {
                        println!("{name} came along to pane {next}");
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
            tokio::time::sleep(Duration::from_secs(hold)).await;
            conn.client.set_draft(None);
            tokio::time::sleep(client_core::PRESENCE_INTERVAL * 3).await;
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
            if conn.json {
                let doc = crate::json::Audit {
                    records: page.records.iter().map(Into::into).collect(),
                    total: page.total,
                    chain_ok: page.chain_ok,
                };
                return crate::json::print("audit", &doc);
            }
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
