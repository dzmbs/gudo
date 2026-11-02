//! The append-only, hash-chained audit log: `<state>/audit/audit.jsonl`.
//!
//! One JSON object per line with ids, hashes and signatures in hex. Each record's `hash` is
//! SHA-256 over the previous record's hash and the postcard encoding of the record (with an
//! empty `hash`), so an edited, reordered or dropped line breaks the chain. Approval records
//! carry the approver's signature, checked again whenever the chain is verified. Raw
//! keystrokes and prompt text are never logged, only lengths and hashes.

use std::collections::VecDeque;
use std::fs::{File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use proto::{
    Actor, ApprovalAudit, AuditKind, AuditPage, AuditQuery, AuditRecord, DeviceId, GrantId,
    OptionId, PaneId, PrincipalId, RequestId, UnixMillis,
};
use serde::{Deserialize, Serialize};

use crate::core::lock;
use crate::fsutil::{hex, unhex};

/// Records kept in memory for queries (older ones stay on disk).
const KEEP: usize = 10_000;

pub(crate) struct Audit {
    path: PathBuf,
    state: Mutex<State>,
}

struct State {
    file: Option<File>,
    last_hash: [u8; 32],
    seq: u64,
    recent: VecDeque<AuditRecord>,
    /// Every record loaded or written so far verified.
    chain_ok: bool,
}

/// What a caller records; the log fills in `seq`, `at` and the hashes.
#[derive(Debug, Default)]
pub(crate) struct Entry {
    pub actor: Option<Actor>,
    pub grant_id: Option<GrantId>,
    pub pane_id: Option<PaneId>,
    pub detail: String,
    pub approval: Option<ApprovalAudit>,
}

impl Audit {
    /// Opens (creating) the log under `state_dir` and verifies what is there.
    pub fn open(state_dir: &Path) -> io::Result<Self> {
        let dir = state_dir.join("audit");
        crate::fsutil::create_private_dir(&dir)?;
        let path = dir.join("audit.jsonl");
        let mut state = State {
            file: None,
            last_hash: [0; 32],
            seq: 0,
            recent: VecDeque::new(),
            chain_ok: true,
        };
        if let Ok(file) = File::open(&path) {
            for line in BufReader::new(file).lines() {
                let line = line?;
                if line.trim().is_empty() {
                    continue;
                }
                let Some(record) = serde_json::from_str::<DiskRecord>(&line)
                    .ok()
                    .and_then(DiskRecord::into_record)
                else {
                    tracing::warn!("audit log: unreadable record after seq {}", state.seq);
                    state.chain_ok = false;
                    continue;
                };
                if !verify_record(&record, &state.last_hash) {
                    tracing::warn!(seq = record.seq, "audit log: hash chain broken");
                    state.chain_ok = false;
                }
                state.last_hash = record.hash.as_slice().try_into().unwrap_or([0; 32]);
                state.seq = record.seq;
                if state.recent.len() == KEEP {
                    state.recent.pop_front();
                }
                state.recent.push_back(record);
            }
        }
        state.file = Some(open_append(&path)?);
        Ok(Self {
            path,
            state: Mutex::new(state),
        })
    }

    pub fn append(&self, kind: AuditKind, entry: Entry) -> AuditRecord {
        let mut state = lock(&self.state);
        let mut record = AuditRecord {
            seq: state.seq + 1,
            at: UnixMillis(crate::identity::now_millis()),
            kind,
            actor: entry.actor,
            grant_id: entry.grant_id,
            pane_id: entry.pane_id,
            detail: entry.detail,
            approval: entry.approval,
            prev_hash: state.last_hash.to_vec(),
            hash: Vec::new(),
        };
        let hash = record_hash(&record, &state.last_hash);
        record.hash = hash.to_vec();
        let mut line = serde_json::to_vec(&DiskRecord::from(&record)).expect("records encode");
        line.push(b'\n');
        let written = state.file.as_mut().map(|file| {
            file.write_all(&line)?;
            // Approvals are what someone may later have to prove; make them durable now.
            if kind == AuditKind::Approval {
                file.sync_data()?;
            }
            Ok::<_, io::Error>(())
        });
        if let Some(Err(error)) = written {
            tracing::warn!("audit log {}: {error}", self.path.display());
        }
        state.seq = record.seq;
        state.last_hash = hash;
        if state.recent.len() == KEEP {
            state.recent.pop_front();
        }
        state.recent.push_back(record.clone());
        record
    }

    /// A page of records, oldest first, plus whether the chain verifies.
    pub fn query(&self, query: AuditQuery) -> AuditPage {
        let state = lock(&self.state);
        let limit = query.limit.clamp(1, 1000) as usize;
        let records: Vec<AuditRecord> = match query.after {
            Some(after) => state
                .recent
                .iter()
                .filter(|record| record.seq > after)
                .take(limit)
                .cloned()
                .collect(),
            None => {
                let start = state.recent.len().saturating_sub(limit);
                state.recent.range(start..).cloned().collect()
            }
        };
        AuditPage {
            records,
            total: state.seq,
            chain_ok: state.chain_ok,
        }
    }

    /// Re-reads the file from disk and verifies the whole chain and every approval signature.
    pub fn verify_file(&self) -> bool {
        let Ok(file) = File::open(&self.path) else {
            return false;
        };
        let mut prev_hash = [0; 32];
        for line in BufReader::new(file).lines() {
            let Ok(line) = line else { return false };
            if line.trim().is_empty() {
                continue;
            }
            let Some(record) = serde_json::from_str::<DiskRecord>(&line)
                .ok()
                .and_then(DiskRecord::into_record)
            else {
                return false;
            };
            if !verify_record(&record, &prev_hash) {
                return false;
            }
            prev_hash = record.hash.as_slice().try_into().unwrap_or([0; 32]);
        }
        true
    }
}

fn open_append(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
}

fn record_hash(record: &AuditRecord, prev_hash: &[u8; 32]) -> [u8; 32] {
    let mut unhashed = record.clone();
    unhashed.hash = Vec::new();
    let body = postcard::to_stdvec(&unhashed).expect("records encode");
    grants::sha256(&[b"audit-v1\0", prev_hash, &body])
}

fn verify_record(record: &AuditRecord, prev_hash: &[u8; 32]) -> bool {
    if record.prev_hash != prev_hash || record.hash != record_hash(record, prev_hash) {
        return false;
    }
    match (&record.approval, &record.actor) {
        (Some(approval), Some(actor)) => {
            grants::verify_signature(actor.device, &approval.signed, &approval.sig)
        }
        (Some(_), None) => false,
        _ => true,
    }
}

#[derive(Serialize, Deserialize)]
struct DiskActor {
    principal: String,
    device: String,
}

#[derive(Serialize, Deserialize)]
struct DiskApproval {
    request_id: u64,
    agent_request: String,
    option_id: u32,
    option: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tool: Option<String>,
    summary: String,
    signed: String,
    sig: String,
}

#[derive(Serialize, Deserialize)]
struct DiskRecord {
    seq: u64,
    at: u64,
    kind: AuditKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    actor: Option<DiskActor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    grant: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pane: Option<u64>,
    detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approval: Option<DiskApproval>,
    prev_hash: String,
    hash: String,
}

impl From<&AuditRecord> for DiskRecord {
    fn from(record: &AuditRecord) -> Self {
        Self {
            seq: record.seq,
            at: record.at.0,
            kind: record.kind,
            actor: record.actor.map(|actor| DiskActor {
                principal: hex(&actor.principal.0),
                device: hex(&actor.device.0),
            }),
            grant: record.grant_id.map(|grant| hex(&grant.0)),
            pane: record.pane_id.map(|pane| pane.0),
            detail: record.detail.clone(),
            approval: record.approval.as_ref().map(|approval| DiskApproval {
                request_id: approval.request_id.0,
                agent_request: approval.agent_request.clone(),
                option_id: approval.option_id.0,
                option: approval.option.clone(),
                tool: approval.tool.clone(),
                summary: approval.summary.clone(),
                signed: hex(&approval.signed),
                sig: hex(&approval.sig),
            }),
            prev_hash: hex(&record.prev_hash),
            hash: hex(&record.hash),
        }
    }
}

fn unhex_vec(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}

impl DiskRecord {
    fn into_record(self) -> Option<AuditRecord> {
        let actor = match self.actor {
            Some(actor) => Some(Actor {
                principal: PrincipalId(unhex(&actor.principal)?),
                device: DeviceId(unhex(&actor.device)?),
            }),
            None => None,
        };
        let grant_id = match self.grant {
            Some(grant) => Some(GrantId(unhex(&grant)?)),
            None => None,
        };
        let approval = match self.approval {
            Some(approval) => Some(ApprovalAudit {
                request_id: RequestId(approval.request_id),
                agent_request: approval.agent_request,
                option_id: OptionId(approval.option_id),
                option: approval.option,
                tool: approval.tool,
                summary: approval.summary,
                signed: unhex_vec(&approval.signed)?,
                sig: unhex_vec(&approval.sig)?,
            }),
            None => None,
        };
        Some(AuditRecord {
            seq: self.seq,
            at: UnixMillis(self.at),
            kind: self.kind,
            actor,
            grant_id,
            pane_id: self.pane.map(PaneId),
            detail: self.detail,
            approval,
            prev_hash: unhex_vec(&self.prev_hash)?,
            hash: unhex_vec(&self.hash)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chain_survives_reopen_and_detects_edits() {
        let dir = tempfile::tempdir().unwrap();
        let key = grants::DeviceKey::generate();
        let actor = grants::guest_actor(key.device_id());
        {
            let log = Audit::open(dir.path()).unwrap();
            log.append(
                AuditKind::Join,
                Entry {
                    actor: Some(actor),
                    detail: "bob joined".into(),
                    ..Entry::default()
                },
            );
            let signed = b"approve".to_vec();
            log.append(
                AuditKind::Approval,
                Entry {
                    actor: Some(actor),
                    approval: Some(ApprovalAudit {
                        request_id: RequestId(1),
                        agent_request: "toolu_1".into(),
                        option_id: OptionId(0),
                        option: "Yes".into(),
                        tool: Some("Bash".into()),
                        summary: "rm -rf x".into(),
                        sig: key.sign(&signed),
                        signed,
                    }),
                    ..Entry::default()
                },
            );
        }
        let log = Audit::open(dir.path()).unwrap();
        let page = log.query(AuditQuery {
            after: None,
            limit: 10,
        });
        assert!(page.chain_ok);
        assert_eq!(page.total, 2);
        assert!(log.verify_file());
        let third = log.append(AuditKind::Leave, Entry::default());
        assert_eq!(third.seq, 3);
        assert_eq!(third.prev_hash, page.records[1].hash);

        let path = dir.path().join("audit/audit.jsonl");
        let text = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, text.replace("bob joined", "eve joined")).unwrap();
        assert!(!log.verify_file());
        assert!(
            !Audit::open(dir.path())
                .unwrap()
                .query(AuditQuery {
                    after: None,
                    limit: 1
                })
                .chain_ok
        );
    }
}
