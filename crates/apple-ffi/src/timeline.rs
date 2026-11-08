use client_core::proto;

use crate::client::DaemonClient;
use crate::ws_types::WorkspaceError;

fn encoded<T: serde::Serialize>(value: &T) -> Result<String, proto::WsError> {
    serde_json::to_string(value).map_err(|error| proto::WsError::Failed(error.to_string()))
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
            encoded(&client.timeline_watch(proto::PaneId(pane_id)).await?)
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
    encoded(update).unwrap_or_else(|_| "{\"operations\":[{\"Unavailable\":{\"message\":\"Chat could not read this update. Open Terminal.\"}}]}".into())
}

#[cfg(test)]
mod tests {
    use super::*;

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
