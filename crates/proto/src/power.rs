use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PowerPolicy {
    Always,
    #[default]
    WhenPluggedIn,
    Never,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PowerStatus {
    pub policy: PowerPolicy,
    pub keeping_awake: bool,
}
