use proto::{DaemonFeatures, PaneId, WorkspaceRequest, WsError};

pub(crate) fn request(
    features: DaemonFeatures,
    pane_id: PaneId,
    handle: String,
) -> Result<WorkspaceRequest, WsError> {
    let required = DaemonFeatures::AGENT_TIMELINE | DaemonFeatures::TIMELINE_TOOL_DIFF;
    if !features.contains(required) {
        return Err(WsError::Unavailable(
            "Update the helper to read complete recorded changes.".into(),
        ));
    }
    Ok(WorkspaceRequest::TimelineToolDiff { pane_id, handle })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_peers_never_get_an_unknown_recorded_diff_request() {
        for features in [
            DaemonFeatures::default(),
            DaemonFeatures::AGENT_TIMELINE,
            DaemonFeatures::TIMELINE_TOOL_DIFF,
        ] {
            assert!(matches!(
                request(features, PaneId(7), "handle".into()),
                Err(WsError::Unavailable(_))
            ));
        }
        let supported = DaemonFeatures::AGENT_TIMELINE | DaemonFeatures::TIMELINE_TOOL_DIFF;
        assert_eq!(
            request(supported, PaneId(7), "handle".into()).unwrap(),
            WorkspaceRequest::TimelineToolDiff {
                pane_id: PaneId(7),
                handle: "handle".into()
            }
        );
    }
}
