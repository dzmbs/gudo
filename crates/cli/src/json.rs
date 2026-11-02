//! `--json`: the read commands' output for scripts, one JSON document per command.
//!
//! Every document is `{"v": 1, "kind": "<command>", …}`. Version 1 only gains fields and
//! kinds; a field is never renamed, retyped or dropped (that is version 2). Ids use the
//! terminal tools' forms (`p12`, `t3`, `s1`). Documented in docs/DAEMON.md ("Scripting"); the
//! goldens in `tests` pin the shapes.

use client_core::proto::{
    AttentionItem, AttentionKind, AuditRecord, CommandMark, DaemonInfo, GitStatus, LayoutNode,
    Link, LinkSource, Participant, PortInfo, PresenceState, SearchPage, SessionLayout,
    SessionSummary, pane_ref, session_ref, tab_ref,
};
use serde::Serialize;

/// The schema version of every document.
pub const VERSION: u32 = 1;

/// Prints one document.
pub fn print<T: Serialize>(kind: &str, body: &T) -> anyhow::Result<()> {
    println!("{}", serde_json::to_string(&document(kind, body)?)?);
    Ok(())
}

fn document<T: Serialize>(kind: &str, body: &T) -> anyhow::Result<serde_json::Value> {
    let mut doc = serde_json::json!({ "v": VERSION, "kind": kind });
    let serde_json::Value::Object(fields) = serde_json::to_value(body)? else {
        anyhow::bail!("a document body is an object");
    };
    doc.as_object_mut().expect("an object").extend(fields);
    Ok(doc)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `gudo ls`.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Ls {
    sessions: Vec<Session>,
    /// The attached session.
    attached: Option<String>,
    tabs: Vec<Tab>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Session {
    id: String,
    name: String,
    tabs: u32,
    panes: u32,
    clients: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Tab {
    id: String,
    /// From 1, as `gudo tab select` takes it.
    index: usize,
    name: String,
    active: bool,
    focused: String,
    zoomed: Option<String>,
    panes: Vec<String>,
}

impl Ls {
    pub fn new(sessions: &[SessionSummary], layout: &SessionLayout) -> Self {
        Self {
            sessions: sessions
                .iter()
                .map(|session| Session {
                    id: session_ref(session.session_id),
                    name: session.name.clone(),
                    tabs: session.tabs,
                    panes: session.panes,
                    clients: session.clients,
                })
                .collect(),
            attached: Some(session_ref(layout.session_id)),
            tabs: layout
                .tabs
                .iter()
                .enumerate()
                .map(|(i, tab)| Tab {
                    id: tab_ref(tab.tab_id),
                    index: i + 1,
                    name: tab.name.clone(),
                    active: Some(tab.tab_id) == layout.active_tab,
                    focused: pane_ref(tab.focused),
                    zoomed: tab.zoomed.map(pane_ref),
                    panes: leaves(&tab.root).into_iter().map(pane_ref).collect(),
                })
                .collect(),
        }
    }
}

fn leaves(node: &LayoutNode) -> Vec<client_core::proto::PaneId> {
    match node {
        LayoutNode::Leaf(pane) => vec![*pane],
        LayoutNode::Split { first, second, .. } => {
            let mut panes = leaves(first);
            panes.extend(leaves(second));
            panes
        }
    }
}

/// A shell-integration command (`gudo marks`, `gudo output`).
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Command {
    id: u64,
    pane: String,
    command: Option<String>,
    cwd: Option<String>,
    started_at: u64,
    /// `running` or `exited`.
    status: &'static str,
    exit_code: Option<i32>,
    duration_ms: Option<u64>,
}

impl From<&CommandMark> for Command {
    fn from(mark: &CommandMark) -> Self {
        Self {
            id: mark.command_id,
            pane: pane_ref(mark.pane_id),
            command: mark.command.clone(),
            cwd: mark.cwd.clone(),
            started_at: mark.started_at.0,
            status: if mark.finished.is_some() {
                "exited"
            } else {
                "running"
            },
            exit_code: mark.finished.and_then(|finished| finished.exit),
            duration_ms: mark.finished.map(|finished| finished.duration_ms),
        }
    }
}

/// `gudo marks`.
#[derive(Serialize)]
pub struct Marks {
    pub commands: Vec<Command>,
}

/// `gudo output`.
#[derive(Serialize)]
pub struct Output {
    pub command: Command,
    pub text: String,
    pub truncated: bool,
}

/// `gudo search`.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Search {
    total: u32,
    total_rows: u64,
    matches: Vec<Match>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Match {
    row: u64,
    col: u16,
    end_row: u64,
    end_col: u16,
    line: String,
}

impl From<&SearchPage> for Search {
    fn from(page: &SearchPage) -> Self {
        Self {
            total: page.total,
            total_rows: page.total_rows,
            matches: page
                .matches
                .iter()
                .map(|found| Match {
                    row: found.row,
                    col: found.col,
                    end_row: found.end_row,
                    end_col: found.end_col,
                    line: found.line.trim_end().to_owned(),
                })
                .collect(),
        }
    }
}

/// `gudo links`.
#[derive(Serialize)]
pub struct Links {
    pub links: Vec<LinkOut>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkOut {
    /// `hyperlink`, `url` or `path`.
    kind: String,
    text: String,
    target: String,
    line: Option<u32>,
    column: Option<u32>,
    exists: Option<bool>,
    /// The command whose output it is in, or `None` for the screen.
    command: Option<u64>,
}

impl From<&Link> for LinkOut {
    fn from(link: &Link) -> Self {
        Self {
            kind: format!("{:?}", link.kind).to_ascii_lowercase(),
            text: link.text.clone(),
            target: link.target.clone(),
            line: link.line,
            column: link.column,
            exists: link.exists,
            command: match link.source {
                LinkSource::Screen => None,
                LinkSource::Command { command_id } => Some(command_id),
            },
        }
    }
}

/// `gudo ports`.
#[derive(Serialize)]
pub struct Ports {
    pub ports: Vec<Port>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Port {
    port: u16,
    /// `http`, `tcp`, … as the daemon classifies it.
    kind: String,
    pane: Option<String>,
    pid: u32,
    process: String,
    loopback_only: bool,
    url: Option<String>,
}

impl From<&PortInfo> for Port {
    fn from(info: &PortInfo) -> Self {
        Self {
            port: info.port,
            kind: format!("{:?}", info.kind).to_ascii_lowercase(),
            pane: info.pane_id.map(pane_ref),
            pid: info.pid,
            process: info.process.clone(),
            loopback_only: info.loopback_only,
            url: info.url.clone(),
        }
    }
}

/// `gudo inbox`.
#[derive(Serialize)]
pub struct Inbox {
    pub items: Vec<Item>,
    pub unseen: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    id: u64,
    at: u64,
    pane: String,
    session: Option<String>,
    /// `blocked`, `done`, `failed` or `command`.
    kind: &'static str,
    title: String,
    body: String,
    seen: bool,
}

impl From<&AttentionItem> for Item {
    fn from(item: &AttentionItem) -> Self {
        Self {
            id: item.id,
            at: item.at.0,
            pane: pane_ref(item.pane_id),
            session: item.session_id.map(session_ref),
            kind: match item.kind {
                AttentionKind::AgentBlocked { .. } => "blocked",
                AttentionKind::AgentDone { .. } => "done",
                AttentionKind::AgentFailed { .. } => "failed",
                AttentionKind::CommandFinished(_) => "command",
            },
            title: item.title.clone(),
            body: item.body.clone(),
            seen: item.seen,
        }
    }
}

/// `gudo git status`.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Git {
    root: String,
    branch: Option<String>,
    head: Option<String>,
    upstream: Option<String>,
    ahead: u32,
    behind: u32,
    files: Vec<GitFile>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GitFile {
    path: String,
    orig_path: Option<String>,
    staged: String,
    unstaged: String,
}

impl From<&GitStatus> for Git {
    fn from(status: &GitStatus) -> Self {
        let change = |change: &dyn std::fmt::Debug| format!("{change:?}").to_ascii_lowercase();
        Self {
            root: status.root.clone(),
            branch: status.branch.clone(),
            head: status.head.clone(),
            upstream: status.upstream.clone(),
            ahead: status.ahead,
            behind: status.behind,
            files: status
                .files
                .iter()
                .map(|file| GitFile {
                    path: file.path.clone(),
                    orig_path: file.orig_path.clone(),
                    staged: change(&file.staged),
                    unstaged: change(&file.unstaged),
                })
                .collect(),
        }
    }
}

/// `gudo who`.
#[derive(Serialize)]
pub struct Who {
    pub participants: Vec<Person>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Person {
    name: String,
    /// The device key, hex.
    device: String,
    roles: String,
    scope: String,
    /// `active`, `idle` or `away`.
    state: &'static str,
    focus: Option<String>,
    typing: bool,
    since: u64,
    you: bool,
}

impl Person {
    pub fn new(participant: &Participant, me: Option<client_core::proto::DeviceId>) -> Self {
        Self {
            name: participant.name.clone(),
            device: hex(&participant.actor.device.0),
            roles: participant.roles.names(),
            scope: participant.scope.to_string(),
            state: match participant.state {
                PresenceState::Active => "active",
                PresenceState::Idle => "idle",
                PresenceState::Away => "away",
            },
            focus: participant.focus.map(pane_ref),
            typing: participant.typing,
            since: participant.since.0,
            you: Some(participant.actor.device) == me,
        }
    }
}

/// `gudo audit`.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Audit {
    pub records: Vec<Record>,
    pub total: u64,
    /// The hash chain and every approval signature verified.
    pub chain_ok: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    seq: u64,
    at: u64,
    kind: String,
    device: Option<String>,
    pane: Option<String>,
    detail: String,
    /// For approvals: the option chosen and what it allowed.
    option: Option<String>,
    summary: Option<String>,
    signed: bool,
}

impl From<&AuditRecord> for Record {
    fn from(record: &AuditRecord) -> Self {
        Self {
            seq: record.seq,
            at: record.at.0,
            kind: format!("{:?}", record.kind),
            device: record.actor.map(|actor| hex(&actor.device.0)),
            pane: record.pane_id.map(pane_ref),
            detail: record.detail.clone(),
            option: record
                .approval
                .as_ref()
                .map(|approval| approval.option.clone()),
            summary: record
                .approval
                .as_ref()
                .map(|approval| approval.summary.clone()),
            signed: record.approval.is_some(),
        }
    }
}

/// `gudo daemon info`.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    version: String,
    build: String,
    built_unix: u64,
    protocol: u32,
    hostname: String,
    os: String,
    os_name: String,
    arch: String,
}

impl From<&DaemonInfo> for Info {
    fn from(info: &DaemonInfo) -> Self {
        Self {
            version: info.version.clone(),
            build: info.build.clone(),
            built_unix: info.built_unix,
            protocol: info.protocol,
            hostname: info.hostname.clone(),
            os: info.os.clone(),
            os_name: info.os_name.clone(),
            arch: info.arch.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use client_core::proto::{
        AttentionKind, CommandEnd, LayoutNode, PaneId, Seq, SessionId, TabId, TabLayout, UnixMillis,
    };

    use super::*;

    /// Compares with `tests/golden/<name>.json`; `UPDATE_UN_GOLDEN=1` writes it instead.
    fn golden<T: Serialize>(name: &str, kind: &str, body: &T) {
        let got = serde_json::to_string_pretty(&document(kind, body).unwrap()).unwrap() + "\n";
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/golden")
            .join(format!("{name}.json"));
        if std::env::var_os("UPDATE_UN_GOLDEN").is_some() {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, &got).unwrap();
            return;
        }
        let want = std::fs::read_to_string(&path).unwrap_or_else(|_| {
            panic!("no golden {}; run with UPDATE_UN_GOLDEN=1", path.display())
        });
        assert_eq!(
            got, want,
            "{name}: the --json schema changed (v{VERSION} may only add)"
        );
    }

    fn mark(finished: bool) -> CommandMark {
        CommandMark {
            pane_id: PaneId(4),
            command_id: 2,
            command: Some("cargo test".into()),
            cwd: Some("/src/app".into()),
            started_at: UnixMillis(1_700_000_000_000),
            at_seq: Seq(10),
            finished: finished.then_some(CommandEnd {
                exit: Some(101),
                duration_ms: 2500,
            }),
        }
    }

    #[test]
    fn documents_keep_their_shape() {
        let layout = SessionLayout {
            session_id: SessionId(1),
            name: "main".into(),
            tabs: vec![TabLayout {
                tab_id: TabId(3),
                name: "api".into(),
                root: LayoutNode::Split {
                    axis: client_core::proto::Axis::Horizontal,
                    ratio: 0.5,
                    first: Box::new(LayoutNode::Leaf(PaneId(4))),
                    second: Box::new(LayoutNode::Leaf(PaneId(5))),
                },
                focused: PaneId(4),
                zoomed: None,
            }],
            active_tab: Some(TabId(3)),
            revision: 7,
        };
        let sessions = [SessionSummary {
            session_id: SessionId(1),
            name: "main".into(),
            tabs: 1,
            panes: 2,
            clients: 1,
        }];
        golden("ls", "ls", &Ls::new(&sessions, &layout));
        golden(
            "marks",
            "marks",
            &Marks {
                commands: vec![(&mark(true)).into(), (&mark(false)).into()],
            },
        );
        golden(
            "output",
            "output",
            &Output {
                command: (&mark(true)).into(),
                text: "error[E0308]: mismatched types".into(),
                truncated: false,
            },
        );
        golden(
            "ports",
            "ports",
            &Ports {
                ports: vec![
                    (&PortInfo {
                        port: 5173,
                        loopback_only: true,
                        pane_id: Some(PaneId(4)),
                        pid: 4242,
                        process: "node".into(),
                        kind: client_core::proto::PortKind::Http,
                        url: Some("http://localhost:5173/".into()),
                    })
                        .into(),
                ],
            },
        );
        golden(
            "inbox",
            "inbox",
            &Inbox {
                items: vec![
                    (&AttentionItem {
                        id: 9,
                        at: UnixMillis(1_700_000_000_000),
                        pane_id: PaneId(5),
                        session_id: Some(SessionId(1)),
                        kind: AttentionKind::AgentBlocked {
                            agent: "claude".into(),
                            request_id: None,
                        },
                        title: "Claude wants to type into ~/api · zsh".into(),
                        body: "Type “npm test”, then Return".into(),
                        seen: false,
                        while_viewed: false,
                    })
                        .into(),
                ],
                unseen: 1,
            },
        );
    }
}
