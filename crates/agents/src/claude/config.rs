//! Claude Code's model, permission mode and effort: what the installed CLI offers and the
//! arguments that start it with them.

use std::ffi::OsString;

use proto::{AgentChoice, AgentModeChoice, AgentModeRisk};

use super::ClaudeCode;
use crate::launch::LaunchSpec;

/// The models offered when the CLI's help names none: aliases every Claude Code accepts.
const KNOWN_MODELS: [&str; 3] = ["opus", "sonnet", "haiku"];

/// What the installed `claude` accepts, read from `claude --help`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ClaudeCliOptions {
    /// `--model` aliases its help names, in its order.
    pub model_aliases: Vec<String>,
    /// `--permission-mode` choices.
    pub modes: Vec<String>,
    /// `--effort` levels; empty when the CLI has no `--effort`.
    pub efforts: Vec<String>,
}

/// A model, permission mode and effort to start Claude Code with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ClaudeConfig {
    pub model: Option<String>,
    pub mode: Option<String>,
    pub effort: Option<String>,
}

/// The lines of the help entry for `flag`: its own line and its indented continuation.
fn help_entry(help: &str, flag: &str) -> Option<String> {
    let mut lines = help
        .lines()
        .skip_while(|line| !line.trim_start().split([' ', ',']).any(|word| word == flag));
    let first = lines.next()?;
    let mut entry = first.to_owned();
    for line in lines {
        let trimmed = line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('-') {
            break;
        }
        entry.push(' ');
        entry.push_str(trimmed);
    }
    Some(entry)
}

fn words_between(entry: &str, open: char, close: char) -> Vec<String> {
    let Some(start) = entry.rfind(open) else {
        return Vec::new();
    };
    let Some(length) = entry[start + 1..].find(close) else {
        return Vec::new();
    };
    let inside = &entry[start + 1..start + 1 + length];
    let inside = inside.strip_prefix("choices:").unwrap_or(inside);
    inside
        .split(',')
        .map(|word| word.trim().trim_matches('"').trim())
        .filter(|word| is_config_id(word))
        .map(str::to_owned)
        .collect()
}

fn is_config_id(word: &str) -> bool {
    !word.is_empty()
        && word.len() <= proto::MAX_AGENT_CONFIG_ID
        && word
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "-_.[]".contains(character))
}

impl ClaudeCliOptions {
    /// Reads `claude --help`.
    ///
    /// # Examples
    ///
    /// ```
    /// let help = "  --effort <level>    Effort level\n                      (low, high)\n";
    /// let options = agents::ClaudeCliOptions::parse(help);
    /// assert_eq!(options.efforts, ["low", "high"]);
    /// assert!(options.modes.is_empty());
    /// ```
    pub fn parse(help: &str) -> Self {
        let model_aliases = help_entry(help, "--model")
            .map(|entry| {
                entry
                    .split('\'')
                    .skip(1)
                    .step_by(2)
                    .filter(|word| is_config_id(word))
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        Self {
            model_aliases,
            modes: help_entry(help, "--permission-mode")
                .map(|entry| words_between(&entry, '(', ')'))
                .unwrap_or_default(),
            efforts: help_entry(help, "--effort")
                .map(|entry| words_between(&entry, '(', ')'))
                .unwrap_or_default(),
        }
    }

    /// The models to offer: the help's aliases, then the known ones it left out.
    pub fn models(&self) -> Vec<AgentChoice> {
        let mut ids: Vec<&str> = self.model_aliases.iter().map(String::as_str).collect();
        for known in KNOWN_MODELS {
            if !ids.contains(&known) {
                ids.push(known);
            }
        }
        ids.into_iter()
            .map(|id| AgentChoice {
                id: id.to_owned(),
                label: capitalized(id),
                detail: format!("The latest {}", capitalized(id)),
            })
            .collect()
    }

    /// The permission modes to offer, safest first.
    pub fn mode_choices(&self) -> Vec<AgentModeChoice> {
        const ORDER: [&str; 7] = [
            "default",
            "manual",
            "dontAsk",
            "plan",
            "acceptEdits",
            "auto",
            "bypassPermissions",
        ];
        let mut modes: Vec<&String> = self.modes.iter().collect();
        modes.sort_by_key(|mode| ORDER.iter().position(|known| known == mode));
        modes.into_iter().map(|mode| mode_choice(mode)).collect()
    }

    pub fn effort_choices(&self) -> Vec<AgentChoice> {
        self.efforts
            .iter()
            .map(|effort| AgentChoice {
                id: effort.clone(),
                label: match effort.as_str() {
                    "xhigh" => "Extra high".into(),
                    other => capitalized(other),
                },
                detail: String::new(),
            })
            .collect()
    }
}

fn capitalized(word: &str) -> String {
    let mut characters = word.chars();
    characters.next().map_or_else(String::new, |first| {
        first.to_uppercase().chain(characters).collect()
    })
}

fn mode_choice(mode: &str) -> AgentModeChoice {
    let (label, detail, risk) = match mode {
        "default" | "manual" => (
            "Ask",
            "Asks before it edits files or runs commands",
            AgentModeRisk::Asks,
        ),
        "dontAsk" => (
            "Don't ask",
            "Runs only what is already allowed and never asks",
            AgentModeRisk::Asks,
        ),
        "plan" => (
            "Plan",
            "Plans without changing anything",
            AgentModeRisk::Plans,
        ),
        "acceptEdits" => (
            "Accept edits",
            "Edits files without asking",
            AgentModeRisk::Edits,
        ),
        "auto" => (
            "Auto",
            "Decides on its own what to ask",
            AgentModeRisk::Automatic,
        ),
        "bypassPermissions" => (
            "Bypass permissions",
            "Never asks before acting",
            AgentModeRisk::Bypass,
        ),
        other => (other, "", AgentModeRisk::Asks),
    };
    AgentModeChoice {
        choice: AgentChoice {
            id: mode.to_owned(),
            label: label.to_owned(),
            detail: detail.to_owned(),
        },
        risk,
    }
}

impl ClaudeConfig {
    /// `--model`, `--permission-mode` and `--effort` for what is set.
    pub fn args(&self) -> Vec<OsString> {
        [
            ("--model", &self.model),
            ("--permission-mode", &self.mode),
            ("--effort", &self.effort),
        ]
        .into_iter()
        .filter_map(|(flag, value)| value.as_ref().map(|value| [flag.into(), value.into()]))
        .flatten()
        .collect()
    }
}

impl ClaudeCode {
    /// Starts `launch` with `config`: its options go before `--mcp-config`, which must stay last
    /// but for `--settings` because it takes several values.
    pub fn apply_config(launch: &mut LaunchSpec, config: &ClaudeConfig) {
        let at = launch
            .args
            .iter()
            .position(|arg| arg == "--mcp-config")
            .unwrap_or(launch.args.len());
        launch.args.splice(at..at, config.args());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NativeSessionId;
    use crate::adapter::AgentAdapter;
    use crate::launch::{LaunchMode, test_context};

    const HELP: &str = r#"Usage: claude [options] [command] [prompt]

Options:
  --effort <level>                      Effort level for the current session
                                        (low, medium, high, xhigh, max)
  --model <model>                       Model for the current session. Use an
                                        alias for the latest model (e.g.
                                        'fable', 'opus', or 'sonnet') or a
                                        model's full name.
  --permission-mode <mode>              Permission mode to use for the session
                                        (choices: "acceptEdits", "auto",
                                        "bypassPermissions", "manual",
                                        "dontAsk", "plan")
  -r, --resume [value]                  Resume a conversation by session ID or
"#;

    #[test]
    fn the_installed_cli_says_what_it_takes() {
        let options = ClaudeCliOptions::parse(HELP);
        assert_eq!(options.model_aliases, ["fable", "opus", "sonnet"]);
        assert_eq!(
            options.modes,
            [
                "acceptEdits",
                "auto",
                "bypassPermissions",
                "manual",
                "dontAsk",
                "plan"
            ]
        );
        assert_eq!(options.efforts, ["low", "medium", "high", "xhigh", "max"]);
        let models: Vec<_> = options.models().into_iter().map(|model| model.id).collect();
        assert_eq!(models, ["fable", "opus", "sonnet", "haiku"]);
        let modes: Vec<_> = options
            .mode_choices()
            .into_iter()
            .map(|mode| (mode.choice.id, mode.risk))
            .collect();
        assert_eq!(modes[0], ("manual".into(), AgentModeRisk::Asks));
        assert_eq!(
            modes.last().cloned(),
            Some(("bypassPermissions".into(), AgentModeRisk::Bypass))
        );
    }

    #[test]
    fn an_older_cli_without_effort_offers_none() {
        let options = ClaudeCliOptions::parse("  --model <model>  Model\n");
        assert!(options.efforts.is_empty());
        assert_eq!(options.models().len(), KNOWN_MODELS.len());
    }

    #[test]
    fn config_goes_before_the_mcp_config() {
        let mode = LaunchMode::Resume {
            session_id: NativeSessionId::new("s1"),
        };
        let mut launch = ClaudeCode::new().launch(&test_context(), &mode);
        ClaudeCode::apply_config(
            &mut launch,
            &ClaudeConfig {
                model: Some("sonnet".into()),
                mode: Some("plan".into()),
                effort: None,
            },
        );
        let args: Vec<_> = launch
            .args
            .iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            &args[..6],
            [
                "--resume",
                "s1",
                "--model",
                "sonnet",
                "--permission-mode",
                "plan"
            ]
        );
        assert_eq!(args[6], "--mcp-config");
        assert_eq!(args[args.len() - 2], "--settings");
    }
}
