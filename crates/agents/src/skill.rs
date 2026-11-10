//! The agent skill the helper installs for Claude Code, Codex and pi: how to work in the
//! product's panes, run commands there, lay them out, start and wait on other agents, and use
//! the browser pane. The files live in `crates/agents/skill/` in the Agent Skills layout, with
//! `{{…}}` placeholders for the product's names.

use crate::launch::mcp_server_name;

/// One file of the skill, at `path` relative to the skill's folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillFile {
    pub path: &'static str,
    pub contents: String,
}

const TEMPLATES: &[(&str, &str)] = &[
    ("SKILL.md", include_str!("../skill/SKILL.md")),
    (
        "references/terminal.md",
        include_str!("../skill/references/terminal.md"),
    ),
    (
        "references/layout.md",
        include_str!("../skill/references/layout.md"),
    ),
    (
        "references/agents.md",
        include_str!("../skill/references/agents.md"),
    ),
    (
        "references/browser.md",
        include_str!("../skill/references/browser.md"),
    ),
    (
        "references/drawings.md",
        include_str!("../skill/references/drawings.md"),
    ),
    (
        "examples/parallel-workers.md",
        include_str!("../skill/examples/parallel-workers.md"),
    ),
    (
        "examples/review-a-diff.md",
        include_str!("../skill/examples/review-a-diff.md"),
    ),
    (
        "examples/dev-server-and-browser.md",
        include_str!("../skill/examples/dev-server-and-browser.md"),
    ),
];

/// The skill's files with this flavour's names filled in; the folder is [`brand::SKILL_NAME`].
pub fn skill_files() -> Vec<SkillFile> {
    TEMPLATES
        .iter()
        .map(|&(path, template)| SkillFile {
            path,
            contents: render(template),
        })
        .collect()
}

fn render(template: &str) -> String {
    let server_name = mcp_server_name();
    let names = [
        ("{{PRODUCT}}", brand::PRODUCT_NAME),
        ("{{SKILL}}", brand::SKILL_NAME),
        ("{{ENV}}", brand::ENV_PREFIX),
        ("{{HOOK_BIN}}", brand::HOOK_BIN),
        ("{{MCP_SERVER}}", server_name.as_str()),
    ];
    names
        .iter()
        .fold(template.to_owned(), |text, (placeholder, name)| {
            text.replace(placeholder, name)
        })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::path::Path;

    use super::*;

    fn frontmatter(skill: &str) -> Vec<(&str, &str)> {
        let body = skill
            .strip_prefix("---\n")
            .and_then(|rest| rest.split_once("\n---\n"))
            .map(|(front, _)| front)
            .expect("SKILL.md starts with frontmatter");
        body.lines()
            .filter_map(|line| line.split_once(": "))
            .collect()
    }

    #[test]
    fn every_placeholder_is_filled() {
        for file in skill_files() {
            assert!(!file.contents.contains("{{"), "{}", file.path);
            assert!(!file.contents.contains('\u{2014}'), "{}", file.path);
            assert!(!file.contents.contains('\u{2013}'), "{}", file.path);
        }
    }

    /// The Agent Skills rules: a name of lowercase words joined by single hyphens that matches
    /// the folder, at most 64 characters, and a description of at most 1024.
    #[test]
    fn frontmatter_follows_the_agent_skills_rules() {
        let files = skill_files();
        let fields = frontmatter(&files[0].contents);
        let field = |key: &str| {
            fields
                .iter()
                .find(|(name, _)| *name == key)
                .map(|(_, value)| *value)
                .unwrap_or_else(|| panic!("no {key}"))
        };
        let name = field("name");
        assert_eq!(name, brand::SKILL_NAME);
        assert!(name.len() <= 64);
        assert!(name.split('-').all(|word| {
            !word.is_empty()
                && word
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        }));
        let description = field("description");
        assert!((100..=1024).contains(&description.len()), "{description}");
        assert!(description.contains(&format!("{}PANE_ID", brand::ENV_PREFIX)));
    }

    #[test]
    fn every_file_in_the_folder_is_bundled_and_every_linked_file_exists() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("skill");
        let mut on_disk = BTreeSet::new();
        let mut folders = vec![root.clone()];
        while let Some(folder) = folders.pop() {
            for entry in std::fs::read_dir(folder).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    folders.push(path);
                } else {
                    let relative = path.strip_prefix(&root).unwrap();
                    on_disk.insert(relative.to_string_lossy().into_owned());
                }
            }
        }
        let bundled: BTreeSet<String> = TEMPLATES
            .iter()
            .map(|(path, _)| (*path).to_owned())
            .collect();
        assert_eq!(on_disk, bundled);
        let links = regex::Regex::new(r"`((?:references|examples)/[a-z-]+\.md)`").unwrap();
        for file in skill_files() {
            for link in links.captures_iter(&file.contents) {
                assert!(
                    bundled.contains(&link[1]),
                    "{} links {}",
                    file.path,
                    &link[1]
                );
            }
        }
    }
}
