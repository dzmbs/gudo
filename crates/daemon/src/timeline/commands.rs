use std::collections::BTreeMap;
use std::io::Read;
use std::path::Path;

use proto::{TimelineCommand, TimelineCommandSource};

const BUILT_INS: &[(&str, &str)] = &[
    ("clear", "Start a fresh conversation"),
    ("compact", "Compact the conversation"),
    ("context", "Show context use"),
    ("cost", "Show this session's cost"),
    ("help", "Show available commands"),
    ("memory", "Manage project memory"),
    ("model", "Choose a model"),
    ("permissions", "Review tool permissions"),
    ("plan", "Switch plan mode"),
    ("rename", "Rename this session"),
    ("status", "Show agent status"),
    ("tasks", "Show background tasks"),
    ("usage", "Show plan usage"),
];

pub(super) fn discover(config: &Path, directory: &Path) -> Vec<TimelineCommand> {
    let mut commands: BTreeMap<String, TimelineCommand> = BUILT_INS
        .iter()
        .map(|(name, description)| {
            (
                name.to_string(),
                TimelineCommand {
                    name: name.to_string(),
                    description: description.to_string(),
                    source: TimelineCommandSource::BuiltIn,
                },
            )
        })
        .collect();
    for (path, source) in [
        (config.join("commands"), TimelineCommandSource::User),
        (
            directory.join(".claude/commands"),
            TimelineCommandSource::Project,
        ),
    ] {
        if let Ok(root) = path.canonicalize() {
            collect(&root, &root, source, 0, &mut commands);
        }
    }
    commands.into_values().collect()
}

fn collect(
    root: &Path,
    directory: &Path,
    source: TimelineCommandSource,
    depth: usize,
    commands: &mut BTreeMap<String, TimelineCommand>,
) {
    if depth > 4 || commands.len() >= 256 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.filter_map(Result::ok).take(512) {
        if commands.len() >= 256 {
            break;
        }
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        let path = entry.path();
        if kind.is_dir() {
            collect(root, &path, source, depth + 1, commands);
            continue;
        }
        if !kind.is_file()
            || path.extension().and_then(|extension| extension.to_str()) != Some("md")
        {
            continue;
        }
        let Ok(relative) = path.strip_prefix(root) else {
            continue;
        };
        let name = relative
            .with_extension("")
            .to_string_lossy()
            .replace(std::path::MAIN_SEPARATOR, ":");
        if name.is_empty()
            || name.len() > 128
            || !name.chars().all(|character| {
                character.is_alphanumeric() || matches!(character, '-' | '_' | ':')
            })
        {
            continue;
        }
        let Ok(file) = std::fs::File::open(&path) else {
            continue;
        };
        let mut bytes = Vec::new();
        if file.take(8192).read_to_end(&mut bytes).is_err() {
            continue;
        }
        let text = String::from_utf8_lossy(&bytes);
        let description = text
            .lines()
            .find_map(|line| line.trim().strip_prefix("description:"))
            .unwrap_or_default()
            .trim()
            .trim_matches(['\'', '"'])
            .chars()
            .take(256)
            .collect();
        commands.insert(
            name.clone(),
            TimelineCommand {
                name,
                description,
                source,
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_commands_override_user_commands_without_following_symlinks() {
        let root = tempfile::tempdir().unwrap();
        let config = root.path().join("config");
        let project = root.path().join("project");
        std::fs::create_dir_all(config.join("commands")).unwrap();
        std::fs::create_dir_all(project.join(".claude/commands/review")).unwrap();
        std::fs::write(
            config.join("commands/test.md"),
            "---\ndescription: User tests\n---\n",
        )
        .unwrap();
        std::fs::write(
            project.join(".claude/commands/test.md"),
            "---\ndescription: 'Project tests'\n---\n",
        )
        .unwrap();
        std::fs::write(
            project.join(".claude/commands/review/tests.md"),
            "---\ndescription: Review tests\n---\n",
        )
        .unwrap();
        std::os::unix::fs::symlink(
            config.join("commands/test.md"),
            project.join(".claude/commands/linked.md"),
        )
        .unwrap();
        let commands = discover(&config, &project);
        assert_eq!(
            commands
                .iter()
                .find(|command| command.name == "test")
                .unwrap()
                .description,
            "Project tests"
        );
        assert!(
            commands
                .iter()
                .any(|command| command.name == "review:tests")
        );
        assert!(!commands.iter().any(|command| command.name == "linked"));
        assert!(commands.iter().any(|command| command.name == "permissions"));
    }
}
