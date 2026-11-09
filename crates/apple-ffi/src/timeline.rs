use client_core::proto;

use crate::client::DaemonClient;
use crate::ws_types::WorkspaceError;

fn encoded<T: serde::Serialize>(value: &T) -> Result<String, proto::WsError> {
    serde_json::to_string(value).map_err(|error| proto::WsError::Failed(error.to_string()))
}

#[derive(serde::Serialize)]
struct SnapshotMetadata<'a> {
    #[serde(flatten)]
    snapshot: &'a proto::TimelineSnapshot,
    capabilities: proto::AgentCapabilities,
}

#[uniffi::export]
impl DaemonClient {
    pub async fn chat_prepare(&self, pane_id: u64) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            encoded(&client.chat_prepare(proto::PaneId(pane_id)).await?)
        })
        .await
    }

    pub async fn chat_send(
        &self,
        pane_id: u64,
        ticket: u64,
        text: String,
        confirmed_revision: Option<u64>,
    ) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            encoded(
                &client
                    .chat_send(proto::PaneId(pane_id), ticket, text, confirmed_revision)
                    .await?,
            )
        })
        .await
    }

    pub async fn chat_interrupt_prepare(&self, pane_id: u64) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            encoded(
                &client
                    .chat_interrupt_prepare(proto::PaneId(pane_id))
                    .await?,
            )
        })
        .await
    }

    pub async fn chat_interrupt(
        &self,
        pane_id: u64,
        ticket: u64,
        confirmed_revision: Option<u64>,
    ) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            encoded(
                &client
                    .chat_interrupt(proto::PaneId(pane_id), ticket, confirmed_revision)
                    .await?,
            )
        })
        .await
    }

    pub async fn timeline_watch(&self, pane_id: u64) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            let snapshot = client
                .timeline_watch_capabilities(proto::PaneId(pane_id))
                .await?;
            encoded(&SnapshotMetadata {
                snapshot: &snapshot.snapshot,
                capabilities: snapshot.capabilities,
            })
        })
        .await
    }

    pub async fn timeline_unwatch(&self, pane_id: u64) -> Result<(), WorkspaceError> {
        self.ws_call(|client| async move { client.timeline_unwatch(proto::PaneId(pane_id)).await })
            .await
    }

    pub async fn timeline_items_before(
        &self,
        pane_id: u64,
        before: u64,
        limit: u16,
    ) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            encoded(
                &client
                    .timeline_items_before(proto::PaneId(pane_id), before, limit)
                    .await?,
            )
        })
        .await
    }

    pub async fn timeline_tool_diff(
        &self,
        pane_id: u64,
        handle: String,
    ) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            encoded(
                &client
                    .timeline_tool_diff(proto::PaneId(pane_id), handle)
                    .await?,
            )
        })
        .await
    }

    pub async fn timeline_tool_output(
        &self,
        pane_id: u64,
        handle: String,
        offset: u64,
        len: u32,
    ) -> Result<String, WorkspaceError> {
        self.ws_call(|client| async move {
            encoded(
                &client
                    .timeline_tool_output(proto::PaneId(pane_id), handle, offset, len)
                    .await?,
            )
        })
        .await
    }
}

pub(crate) fn encode_update(update: &proto::TimelineUpdate) -> String {
    encoded(update).unwrap_or_else(|_| unreadable_update(update.pane_id))
}

fn unreadable_update(pane_id: proto::PaneId) -> String {
    serde_json::json!({
        "pane_id": pane_id.0,
        "operations": [
            { "Unavailable": { "message": "Chat could not read this update. Open Terminal." } }
        ],
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_metadata_preserves_the_app_json_shape_and_unknown_feature_bits() {
        let snapshot = proto::TimelineSnapshot {
            cursor: proto::TimelineCursor {
                epoch: 1,
                sequence: 2,
            },
            session: proto::TimelineSession {
                agent: proto::AgentKind::Claude,
                native_session: "fixture".into(),
                title: None,
                model: None,
                permission_mode: None,
                commands: vec![],
            },
            items: vec![],
            before: None,
        };
        let json = encoded(&SnapshotMetadata {
            snapshot: &snapshot,
            capabilities: proto::AgentCapabilities(0x8001),
        })
        .unwrap();
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["capabilities"], 0x8001);
        assert_eq!(
            serde_json::from_str::<proto::TimelineSnapshot>(&json).unwrap(),
            snapshot
        );
    }

    #[test]
    fn an_unreadable_update_still_names_its_pane_in_the_shape_the_app_decodes() {
        let json = unreadable_update(proto::PaneId(u64::MAX));
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["pane_id"], u64::MAX);
        assert!(value["operations"][0]["Unavailable"]["message"].is_string());
        let decoded: proto::TimelineUpdate = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.pane_id, proto::PaneId(u64::MAX));
        assert!(matches!(
            decoded.operations.as_slice(),
            [proto::TimelineOp::Unavailable { .. }]
        ));
    }

    #[test]
    fn timeline_json_keeps_large_integer_cursors_and_text_exactly() {
        let update = proto::TimelineUpdate {
            pane_id: proto::PaneId(u64::MAX),
            operations: vec![proto::TimelineOp::Append {
                cursor: proto::TimelineCursor {
                    epoch: u64::MAX,
                    sequence: u64::MAX,
                },
                id: "message".into(),
                field: proto::TimelineField::Text,
                text: "Text \"with quotes\"\n🦀".into(),
            }],
        };
        let decoded: proto::TimelineUpdate = serde_json::from_str(&encode_update(&update)).unwrap();
        assert_eq!(decoded, update);
    }
}
