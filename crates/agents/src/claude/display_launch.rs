use std::num::NonZeroU16;

use serde_json::json;

use super::ClaudeCode;
use crate::adapter::AgentAdapter;
use crate::launch::{LaunchContext, LaunchMode, LaunchSpec, SupportFile};

impl ClaudeCode {
    /// Selects display settings in the post-login helper, before starting the official CLI.
    pub fn display_launch(
        &self,
        context: &LaunchContext,
        mode: &LaunchMode,
        port: NonZeroU16,
        token: &str,
    ) -> LaunchSpec {
        let mut launch = self.launch(context, mode);
        let path = Self::settings_path(context).with_file_name(format!(
            "settings.v{}.display.v1.json",
            super::SETTINGS_VERSION
        ));
        let token_variable = brand::env_var("CLAUDE_DISPLAY_TOKEN");
        let pane_variable = brand::env_var("PANE_ID");
        let mut settings = Self::hook_settings(context);
        settings["hooks"]["MessageDisplay"] = json!([{"hooks":[{
            "type":"http",
            "url":format!("http://127.0.0.1:{port}/claude/message-display"),
            "timeout":2,
            "headers":{
                "Authorization":format!("Bearer ${{{token_variable}}}"),
                "X-Gudo-Pane":format!("${{{pane_variable}}}"),
            },
            "allowedEnvVars":[token_variable, pane_variable],
        }]}]);
        launch.files.push(SupportFile {
            path: path.clone(),
            contents: settings.to_string(),
        });
        launch
            .env
            .push((brand::env_var("CLAUDE_DISPLAY_TOKEN"), token.into()));
        launch.program = context.hook_bin.clone().into();
        launch.args.insert(0, path.into());
        launch.args.insert(0, "claude-display".into());
        launch
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NativeSessionId;
    use crate::launch::test_context;

    #[test]
    fn display_settings_are_separate_and_preserve_every_legacy_hook() {
        let context = test_context();
        let adapter = ClaudeCode::new();
        let mode = LaunchMode::Resume {
            session_id: NativeSessionId::new("exact-session"),
        };
        let legacy = adapter.launch(&context, &mode);
        let display = adapter.display_launch(
            &context,
            &mode,
            NonZeroU16::new(12345).unwrap(),
            "fixture-display-secret",
        );
        assert_eq!(&display.args[2..], legacy.args);
        assert_eq!(display.files[..legacy.files.len()], legacy.files);
        assert_eq!(display.env_pinned, legacy.env_pinned);
        assert_eq!(display.env_remove, legacy.env_remove);
        let file = display.files.last().unwrap();
        assert_ne!(file.path, ClaudeCode::settings_path(&context));
        assert!(!file.contents.contains("fixture-display-secret"));
        assert!(!file.contents.contains("displayContent"));
        let mut settings: serde_json::Value = serde_json::from_str(&file.contents).unwrap();
        let hook = &settings["hooks"]["MessageDisplay"][0]["hooks"][0];
        assert_eq!(hook["type"], "http");
        assert_eq!(hook["url"], "http://127.0.0.1:12345/claude/message-display");
        assert_eq!(
            hook["headers"]["Authorization"],
            format!("Bearer ${{{}}}", brand::env_var("CLAUDE_DISPLAY_TOKEN"))
        );
        settings["hooks"]
            .as_object_mut()
            .unwrap()
            .remove("MessageDisplay");
        assert_eq!(settings, ClaudeCode::hook_settings(&context));
    }
}
