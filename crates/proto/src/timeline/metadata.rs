use serde::{Deserialize, Serialize};

// These enums keep the original string representation on both postcard and JSON boundaries.
macro_rules! metadata_enum {
    ($name:ident { $($variant:ident => $wire:literal),+ $(,)? }) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
        #[serde(from = "String", into = "String")]
        pub enum $name { $($variant,)+ Unknown }

        impl From<&str> for $name {
            fn from(value: &str) -> Self {
                match value { $($wire => Self::$variant,)+ _ => Self::Unknown }
            }
        }

        impl From<String> for $name {
            fn from(value: String) -> Self { Self::from(value.as_str()) }
        }

        impl From<$name> for String {
            fn from(value: $name) -> Self {
                match value { $($name::$variant => $wire,)+ $name::Unknown => "Unknown" }.into()
            }
        }
    };
}

metadata_enum!(TimelineCommandSource {
    BuiltIn => "Built-in",
    User => "User",
    Project => "Project",
});

metadata_enum!(TimelinePermissionMode {
    Default => "default",
    AcceptEdits => "acceptEdits",
    Plan => "plan",
    DontAsk => "dontAsk",
    BypassPermissions => "bypassPermissions",
    Auto => "auto",
});
