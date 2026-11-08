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

#[cfg(test)]
mod tests {
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
