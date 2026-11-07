//! The Codex notify argv envelope shared by configuration installation and hook dispatch.

use std::fmt;
use std::path::Path;

pub const CODEX_NOTIFY_SUBCOMMAND: &str = "codex-notify";
const MAX_NOTIFY_CHAIN_DEPTH: usize = 64;

#[derive(Debug)]
pub struct NotifyChain {
    wrappers: Vec<String>,
    leaf: NotifyLeaf,
}

#[derive(Debug)]
enum NotifyLeaf {
    Empty,
    User(Vec<String>),
    Hook(Vec<String>),
}

#[derive(Debug)]
pub enum NotifyChainError {
    TooDeep,
    Json(serde_json::Error),
}

impl fmt::Display for NotifyChainError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooDeep => formatter.write_str("notification chain is too deep"),
            Self::Json(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for NotifyChainError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Json(error) => Some(error),
            Self::TooDeep => None,
        }
    }
}

pub fn is_hook_program(program: &str) -> bool {
    Path::new(program).file_name().is_some_and(|name| {
        name == brand::RELEASE_HOOK_BIN
            || name == brand::DEV_HOOK_BIN
            || name == brand::legacy::HOOK_BIN
    })
}

impl NotifyChain {
    pub fn parse(mut arguments: Vec<String>) -> Result<Self, NotifyChainError> {
        let mut wrappers = Vec::new();
        while arguments
            .first()
            .is_some_and(|program| is_hook_program(program))
        {
            if wrappers.len() == MAX_NOTIFY_CHAIN_DEPTH {
                return Err(NotifyChainError::TooDeep);
            }
            let [program, command, original] = arguments.as_slice() else {
                break;
            };
            if command != CODEX_NOTIFY_SUBCOMMAND {
                break;
            }
            let original = serde_json::from_str(original).map_err(NotifyChainError::Json)?;
            wrappers.push(program.clone());
            arguments = original;
        }
        let leaf = match arguments.first() {
            None => NotifyLeaf::Empty,
            Some(program) if is_hook_program(program) => NotifyLeaf::Hook(arguments),
            Some(_) => NotifyLeaf::User(arguments),
        };
        Ok(Self { wrappers, leaf })
    }

    /// Dispatch only a real user program, never another flavour's hook or a legacy hook argv.
    pub fn into_user_command(self) -> Option<Vec<String>> {
        match self.leaf {
            NotifyLeaf::User(arguments) => Some(arguments),
            NotifyLeaf::Empty | NotifyLeaf::Hook(_) => None,
        }
    }

    /// Installation removes selected hooks while retaining live foreign wrappers in order.
    pub fn remove_hooks(
        self,
        mut removes: impl FnMut(&str) -> bool,
    ) -> Result<Vec<String>, NotifyChainError> {
        let mut arguments = match self.leaf {
            NotifyLeaf::Empty => Vec::new(),
            NotifyLeaf::Hook(arguments)
                if removes(&arguments[0]) && is_legacy_notify(&arguments) =>
            {
                Vec::new()
            }
            NotifyLeaf::Hook(arguments) | NotifyLeaf::User(arguments) => arguments,
        };
        for program in self
            .wrappers
            .into_iter()
            .rev()
            .filter(|program| !removes(program))
        {
            let original = serde_json::to_string(&arguments).map_err(NotifyChainError::Json)?;
            arguments = vec![program, CODEX_NOTIFY_SUBCOMMAND.into(), original];
        }
        Ok(arguments)
    }
}

fn is_legacy_notify(arguments: &[String]) -> bool {
    matches!(arguments, [_, agent, event, ..] if agent == "codex" && event == crate::CODEX_NOTIFY_EVENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wrapper(program: &str, arguments: &[String]) -> Vec<String> {
        vec![
            program.into(),
            CODEX_NOTIFY_SUBCOMMAND.into(),
            serde_json::to_string(arguments).unwrap(),
        ]
    }

    #[test]
    fn all_flavour_wrappers_dispatch_the_same_user_arguments() {
        let user = vec!["my-notify".into(), "spaces and \"quotes\" 🦀".into()];
        let mut arguments = user.clone();
        for program in [
            brand::RELEASE_HOOK_BIN,
            brand::DEV_HOOK_BIN,
            brand::legacy::HOOK_BIN,
        ] {
            arguments = wrapper(&format!("/private/{program}"), &arguments);
        }
        assert_eq!(
            NotifyChain::parse(arguments).unwrap().into_user_command(),
            Some(user)
        );
    }

    #[test]
    fn selective_normalization_preserves_foreign_wrapper_order() {
        let owned = format!("/owned/{}", brand::RELEASE_HOOK_BIN);
        let foreign = format!("/foreign/{}", brand::DEV_HOOK_BIN);
        let user = vec!["user-notify".into(), "argument with spaces".into()];
        let arguments = wrapper(&foreign, &wrapper(&owned, &wrapper(&foreign, &user)));
        let actual = NotifyChain::parse(arguments)
            .unwrap()
            .remove_hooks(|program| program == owned)
            .unwrap();
        assert_eq!(actual, wrapper(&foreign, &wrapper(&foreign, &user)));
    }

    #[test]
    fn malformed_envelopes_fail_closed_but_unknown_hook_arguments_are_preserved() {
        let program = brand::RELEASE_HOOK_BIN;
        assert!(
            NotifyChain::parse(vec![
                program.into(),
                CODEX_NOTIFY_SUBCOMMAND.into(),
                "[1]".into()
            ])
            .is_err()
        );
        let unknown = vec![program.into(), "future-command".into()];
        assert!(
            NotifyChain::parse(unknown.clone())
                .unwrap()
                .into_user_command()
                .is_none()
        );
        assert_eq!(
            NotifyChain::parse(unknown.clone())
                .unwrap()
                .remove_hooks(|_| true)
                .unwrap(),
            unknown
        );
    }

    #[test]
    fn legacy_hook_commands_are_not_user_programs() {
        let arguments = vec![
            brand::RELEASE_HOOK_BIN.into(),
            "codex".into(),
            crate::CODEX_NOTIFY_EVENT.into(),
        ];
        assert!(
            NotifyChain::parse(arguments.clone())
                .unwrap()
                .into_user_command()
                .is_none()
        );
        assert!(
            NotifyChain::parse(arguments.clone())
                .unwrap()
                .remove_hooks(|_| true)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            NotifyChain::parse(arguments.clone())
                .unwrap()
                .remove_hooks(|_| false)
                .unwrap(),
            arguments
        );
    }

    #[test]
    fn suffixed_foreign_programs_are_not_hooks() {
        let user = vec![
            format!("/private/{}-custom", brand::RELEASE_HOOK_BIN),
            CODEX_NOTIFY_SUBCOMMAND.into(),
            "not JSON".into(),
        ];
        assert_eq!(
            NotifyChain::parse(user.clone())
                .unwrap()
                .into_user_command(),
            Some(user)
        );
    }

    #[test]
    fn existing_string_array_encoding_is_unchanged() {
        assert_eq!(CODEX_NOTIFY_SUBCOMMAND, "codex-notify");
        let arguments = wrapper(
            brand::RELEASE_HOOK_BIN,
            &["user-notify".into(), "🦀".into()],
        );
        assert_eq!(
            NotifyChain::parse(arguments.clone())
                .unwrap()
                .remove_hooks(|_| false)
                .unwrap(),
            arguments
        );
        assert!(
            NotifyChain::parse(Vec::new())
                .unwrap()
                .into_user_command()
                .is_none()
        );
    }
}
