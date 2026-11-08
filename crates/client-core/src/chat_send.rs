use proto::{DaemonFeatures, WsError};

pub(crate) fn require(features: DaemonFeatures) -> Result<(), WsError> {
    if features.contains(DaemonFeatures::CHAT_SEND) {
        Ok(())
    } else {
        Err(WsError::Unavailable(
            "Update the helper to send from Chat.".into(),
        ))
    }
}

pub(crate) fn require_interrupt(features: DaemonFeatures) -> Result<(), WsError> {
    if features.contains(DaemonFeatures::CHAT_INTERRUPT) {
        Ok(())
    } else {
        Err(WsError::Unavailable(
            "Update the helper to interrupt from Chat.".into(),
        ))
    }
}

// Legacy readable timelines expose this block-level feature contract; controls still need their own bits.
pub(crate) fn legacy_capabilities(features: DaemonFeatures) -> proto::AgentCapabilities {
    use proto::AgentCapabilities as Capabilities;
    let mut capabilities = Capabilities::READ | Capabilities::THINKING | Capabilities::PLANS;
    if features.contains(DaemonFeatures::CHAT_SEND) {
        capabilities |= Capabilities::SEND | Capabilities::ACKNOWLEDGED_SEND;
    }
    if features.contains(DaemonFeatures::CHAT_INTERRUPT) {
        capabilities |= Capabilities::STOP;
    }
    if features.contains(DaemonFeatures::MP2) {
        capabilities |= Capabilities::APPROVALS;
    }
    if features.contains(DaemonFeatures::TIMELINE_TOOL_DIFF) {
        capabilities |= Capabilities::DIFFS;
    }
    capabilities
}

#[cfg(test)]
mod tests {
    #[test]
    fn legacy_features_never_invent_unsupported_controls() {
        use proto::AgentCapabilities as Capabilities;
        let readable = super::legacy_capabilities(proto::DaemonFeatures::AGENT_TIMELINE);
        assert!(readable.contains(Capabilities::READ));
        for feature in [
            Capabilities::SEND,
            Capabilities::STOP,
            Capabilities::APPROVALS,
            Capabilities::DIFFS,
            Capabilities::STREAMING_DELTAS,
        ] {
            assert!(!readable.contains(feature));
        }
        let controls = super::legacy_capabilities(
            proto::DaemonFeatures::CHAT_SEND | proto::DaemonFeatures::CHAT_INTERRUPT,
        );
        assert!(
            controls.contains(
                Capabilities::SEND | Capabilities::ACKNOWLEDGED_SEND | Capabilities::STOP
            )
        );
    }

    use super::*;

    #[test]
    fn interrupts_need_their_own_capability() {
        assert!(require_interrupt(DaemonFeatures::default()).is_err());
        assert!(require_interrupt(DaemonFeatures::CHAT_SEND).is_err());
        assert!(require_interrupt(DaemonFeatures::CHAT_INTERRUPT).is_ok());
    }

    #[test]
    fn send_is_unavailable_without_the_new_capability() {
        assert!(require(DaemonFeatures::default()).is_err());
        assert!(require(DaemonFeatures::AGENT_TIMELINE).is_err());
        assert!(require(DaemonFeatures::CHAT_SEND).is_ok());
    }
}
