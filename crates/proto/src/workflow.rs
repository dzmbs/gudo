//!
//! The daemon reads `~/.config/<product>/workflows/*.yaml` (global) and
//! `<repository>/.<product>/workflows/*.yaml` (the repository a pane's directory is in), and
//! answers [`WorkspaceRequest::WorkflowList`](crate::WorkspaceRequest::WorkflowList) for a pane
//! with both. Clients with [`Caps::WORKFLOWS`](crate::Caps::WORKFLOWS) get
//! [`ServerCtl::WorkflowsChanged`](crate::ServerCtl::WorkflowsChanged) whenever a file it has
//! read from changes, and ask again.
//!
//! A command holds `{{name}}` placeholders. [`render`] fills them, shell-quoting each value
//! for where the placeholder sits (unquoted, inside `'…'` or inside `"…"`) unless the argument
//! is [`raw`](WorkflowArgument::raw). Nothing here runs anything: the app types the result
//! into a pane and the user presses Return.
//!
//! Same compatibility rules as the rest of the crate: append only.

use std::borrow::Cow;

use serde::{Deserialize, Serialize};

use crate::ids::PaneId;

/// One workflow, as read from a file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workflow {
    /// Stable while the file stays where it is: the file's path, with `#<n>` for the n-th
    /// workflow of a file that holds a list.
    pub id: String,
    /// The title.
    pub name: String,
    /// The command line, with `{{name}}` placeholders.
    pub command: String,
    /// What it does.
    pub description: Option<String>,
    /// Free-form tags (searchable).
    pub tags: Vec<String>,
    /// The placeholders' arguments, in the file's order; placeholders the file does not list
    /// are appended with no description or default.
    pub arguments: Vec<WorkflowArgument>,
    /// Shells it is written for (`bash`, `zsh`, `fish`); empty for any.
    pub shells: Vec<String>,
    /// Who wrote it.
    pub author: Option<String>,
    /// Where it came from.
    pub source_url: Option<String>,
    /// Global or the repository's.
    pub scope: WorkflowScope,
    /// The YAML file on the host.
    pub path: String,
}

/// A `{{name}}` placeholder's argument.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowArgument {
    /// The placeholder's name.
    pub name: String,
    /// What to fill in.
    pub description: Option<String>,
    /// Filled in to start with.
    pub default_value: Option<String>,
    /// Substituted as typed, without shell quoting (`raw: true` in the file), for arguments
    /// that are flags or command fragments.
    pub raw: bool,
}

/// Where a workflow lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum WorkflowScope {
    /// `~/.config/<product>/workflows`: every pane on the host.
    Global,
    /// `<repository>/.<product>/workflows`: panes in that repository.
    Repo,
}

/// The workflows a pane can use → [`WorkspaceResponse::Workflows`](crate::WorkspaceResponse::Workflows).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowList {
    /// Increases whenever a watched workflow directory changes (compare with
    /// [`ServerCtl::WorkflowsChanged`](crate::ServerCtl::WorkflowsChanged)).
    pub rev: u64,
    /// The pane's repository (top level of its worktree), if it is in one.
    pub repo: Option<String>,
    /// The repository's name.
    pub repo_name: Option<String>,
    /// The repository's workflows first (by name), then the global ones (by name).
    pub workflows: Vec<Workflow>,
    /// Files that could not be read, and why.
    pub problems: Vec<WorkflowProblem>,
}

/// A workflow file that was skipped.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowProblem {
    /// The file.
    pub path: String,
    /// Why (one line).
    pub message: String,
}

/// Writes a new workflow file → [`WorkspaceResponse::WorkflowSaved`](crate::WorkspaceResponse::WorkflowSaved).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowSave {
    /// [`WorkflowScope::Global`], or the repository of `pane_id`.
    pub scope: WorkflowScope,
    /// The pane whose repository a [`WorkflowScope::Repo`] workflow goes to.
    pub pane_id: Option<PaneId>,
    /// What to write.
    pub workflow: WorkflowDraft,
}

/// A workflow to save: the file's fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowDraft {
    /// The title (also names the file).
    pub name: String,
    /// The command line, with `{{name}}` placeholders.
    pub command: String,
    /// What it does.
    pub description: Option<String>,
    /// Tags.
    pub tags: Vec<String>,
    /// Arguments of the placeholders.
    pub arguments: Vec<WorkflowArgument>,
    /// Shells it is written for.
    pub shells: Vec<String>,
}

/// The distinct `{{name}}` placeholders of `command`, in order of first use.
///
/// A name starts with a letter or `_` and holds letters, digits, `_` and `-`; spaces inside
/// the braces are allowed. Anything else between braces (Go templates such as
/// `{{.State.Status}}`) is not a placeholder and stays as written.
///
/// # Examples
///
/// ```
/// let names = proto::placeholders("git log {{ branch }} -n {{count}} {{branch}} {{.Id}}");
/// assert_eq!(names, ["branch", "count"]);
/// ```
pub fn placeholders(command: &str) -> Vec<&str> {
    let mut names: Vec<&str> = Vec::new();
    for (_, _, name) in scan(command) {
        if !names.contains(&name) {
            names.push(name);
        }
    }
    names
}

/// `command` with every placeholder replaced by its value: `values` first, else the
/// argument's default, else empty. Values are shell-quoted for where the placeholder sits
/// (see [`shell_quote`], [`quote_in_double`], [`quote_in_single`]) unless the argument is
/// [`raw`](WorkflowArgument::raw).
///
/// # Examples
///
/// ```
/// use proto::{WorkflowArgument, render};
///
/// let arg = |name: &str| WorkflowArgument {
///     name: name.into(),
///     description: None,
///     default_value: None,
///     raw: false,
/// };
/// let out = render(
///     r#"git commit -m "{{msg}}" && echo {{who}}"#,
///     &[arg("msg"), arg("who")],
///     &[("msg", "say \"hi\" $HOME"), ("who", "it's me")],
/// );
/// assert_eq!(out, r#"git commit -m "say \"hi\" \$HOME" && echo 'it'\''s me'"#);
/// ```
pub fn render(command: &str, arguments: &[WorkflowArgument], values: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(command.len());
    let mut last = 0;
    for (start, end, name) in scan(command) {
        out.push_str(&command[last..start]);
        last = end;
        let arg = arguments.iter().find(|a| a.name == name);
        let value = values
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, v)| *v)
            .or_else(|| arg.and_then(|a| a.default_value.as_deref()))
            .unwrap_or("");
        if arg.is_some_and(|a| a.raw) {
            out.push_str(value);
            continue;
        }
        let quoted = match quoting_at(&command[..start]) {
            Quoting::None => shell_quote(value),
            Quoting::Single => quote_in_single(value),
            Quoting::Double => quote_in_double(value),
        };
        out.push_str(&quoted);
    }
    out.push_str(&command[last..]);
    out
}

/// `s` as one POSIX shell word: unchanged when it is only safe characters, else in single
/// quotes with each `'` written `'\''`. Empty is `''`.
///
/// # Examples
///
/// ```
/// assert_eq!(proto::shell_quote("main"), "main");
/// assert_eq!(proto::shell_quote(""), "''");
/// assert_eq!(proto::shell_quote("a b"), "'a b'");
/// assert_eq!(proto::shell_quote("it's"), r"'it'\''s'");
/// ```
pub fn shell_quote(s: &str) -> Cow<'_, str> {
    let safe = |c: char| c.is_ascii_alphanumeric() || "_-.,/:@%+=".contains(c);
    if !s.is_empty() && s.chars().all(safe) {
        Cow::Borrowed(s)
    } else {
        Cow::Owned(format!("'{}'", s.replace('\'', r"'\''")))
    }
}

/// `s` for the inside of a `"…"` string: `\`, `"`, `$` and `` ` `` escaped.
pub fn quote_in_double(s: &str) -> Cow<'_, str> {
    if !s.contains(['\\', '"', '$', '`']) {
        return Cow::Borrowed(s);
    }
    let mut out = String::with_capacity(s.len() + 4);
    for c in s.chars() {
        if matches!(c, '\\' | '"' | '$' | '`') {
            out.push('\\');
        }
        out.push(c);
    }
    Cow::Owned(out)
}

/// `s` for the inside of a `'…'` string: each `'` closes the string, adds an escaped quote
/// and reopens it (`'\''`).
pub fn quote_in_single(s: &str) -> Cow<'_, str> {
    if s.contains('\'') {
        Cow::Owned(s.replace('\'', r"'\''"))
    } else {
        Cow::Borrowed(s)
    }
}

/// Where a position in a command line is, as the shell reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Quoting {
    None,
    Single,
    Double,
}

/// The quoting in force at the end of `prefix`.
fn quoting_at(prefix: &str) -> Quoting {
    let mut state = Quoting::None;
    let mut chars = prefix.chars();
    while let Some(c) = chars.next() {
        match (state, c) {
            (Quoting::None | Quoting::Double, '\\') => {
                chars.next();
            }
            (Quoting::None, '\'') => state = Quoting::Single,
            (Quoting::None, '"') => state = Quoting::Double,
            (Quoting::Single, '\'') | (Quoting::Double, '"') => state = Quoting::None,
            _ => {}
        }
    }
    state
}

/// Every placeholder: its byte range (braces included) and name.
fn scan(command: &str) -> impl Iterator<Item = (usize, usize, &str)> {
    let mut from = 0;
    std::iter::from_fn(move || {
        while let Some(open) = command[from..].find("{{").map(|i| from + i) {
            let Some(close) = command[open + 2..].find("}}").map(|i| open + 2 + i) else {
                from = command.len();
                return None;
            };
            let name = command[open + 2..close].trim();
            if is_name(name) {
                from = close + 2;
                return Some((open, close + 2, name));
            }
            from = open + 1;
        }
        None
    })
}

/// A placeholder name: a letter or `_`, then letters, digits, `_` or `-`.
pub fn is_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arg(name: &str, default: Option<&str>, raw: bool) -> WorkflowArgument {
        WorkflowArgument {
            name: name.into(),
            description: None,
            default_value: default.map(Into::into),
            raw,
        }
    }

    #[test]
    fn placeholders_skip_templates_and_repeat_once() {
        assert_eq!(
            placeholders("docker inspect -f '{{.State.Status}}' {{ container }} {{container}}"),
            ["container"]
        );
        assert_eq!(
            placeholders("{{a}}{{b-c}}{{_d}}{{1x}}{{}}{{ }}"),
            ["a", "b-c", "_d"]
        );
        assert!(placeholders("unclosed {{name").is_empty());
        assert_eq!(placeholders("{{{x}}}"), ["x"]);
    }

    #[test]
    fn values_are_quoted_for_where_they_sit() {
        let args = [arg("v", None, false)];
        let cases = [
            ("echo {{v}}", "a b; rm -rf ~", "echo 'a b; rm -rf ~'"),
            ("echo {{v}}", "$(id)", "echo '$(id)'"),
            ("echo {{v}}", "plain/path-1.2", "echo plain/path-1.2"),
            ("echo {{v}}", "", "echo ''"),
            (
                "echo \"x {{v}} y\"",
                "a\"b$c`d`\\",
                r#"echo "x a\"b\$c\`d\`\\ y""#,
            ),
            ("echo 'x {{v}}'", "it's", r"echo 'x it'\''s'"),
            // An escaped quote does not open a string.
            (r"echo \'{{v}}", "a b", r"echo \''a b'"),
            // A quote inside double quotes does not open a single-quoted string.
            (r#"echo "it's {{v}}""#, "$x", r#"echo "it's \$x""#),
        ];
        for (command, value, want) in cases {
            assert_eq!(render(command, &args, &[("v", value)]), want, "{command}");
        }
    }

    #[test]
    fn defaults_raw_and_unknown_placeholders() {
        let args = [arg("n", Some("10"), false), arg("flags", Some("-a"), true)];
        assert_eq!(
            render("ls {{flags}} | head -n {{n}}", &args, &[]),
            "ls -a | head -n 10"
        );
        assert_eq!(
            render("ls {{flags}}", &args, &[("flags", "-la --color")]),
            "ls -la --color"
        );
        // A placeholder without an argument is still quoted.
        assert_eq!(
            render("echo {{other}}", &args, &[("other", "a b")]),
            "echo 'a b'"
        );
        assert_eq!(render("echo {{other}}", &args, &[]), "echo ''");
    }
}
