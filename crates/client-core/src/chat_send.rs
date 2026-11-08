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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn send_is_unavailable_without_the_new_capability() {
        assert!(require(DaemonFeatures::default()).is_err());
        assert!(require(DaemonFeatures::AGENT_TIMELINE).is_err());
        assert!(require(DaemonFeatures::CHAT_SEND).is_ok());
    }
}
