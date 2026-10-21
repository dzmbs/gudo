//! Workflows on [`DaemonClient`] (`proto::workflow`): YAML files of named commands with
//! `{{arguments}}` on the host, listed per pane (the pane's repository's, then the global
//! ones), changes pushed as [`WorkspaceEvent::WorkflowsChanged`](crate::ws_types::WorkspaceEvent::WorkflowsChanged),
//! new files written by [`DaemonClient::workflow_save`]. [`workflow_render`] fills the
//! placeholders (shell-quoted) for the argument form's live preview and the typed command.

use client_core::proto;

use crate::client::DaemonClient;
use crate::ws_types::WorkspaceError;

/// One workflow.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Workflow {
    /// Stable while its file stays put (the path, `#n` for a file holding a list).
    pub id: String,
    /// The title.
    pub name: String,
    /// The command line with `{{name}}` placeholders.
    pub command: String,
    /// What it does.
    pub description: Option<String>,
    /// Tags.
    pub tags: Vec<String>,
    /// One per placeholder, in order.
    pub arguments: Vec<WorkflowArgument>,
    /// Shells it is written for; empty for any.
    pub shells: Vec<String>,
    /// Who wrote it.
    pub author: Option<String>,
    /// Where it came from.
    pub source_url: Option<String>,
    /// Global or the repository's.
    pub scope: WorkflowScope,
    /// Its YAML file on the host.
    pub path: String,
}

/// A placeholder's argument.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkflowArgument {
    /// The placeholder's name.
    pub name: String,
    /// What to fill in.
    pub description: Option<String>,
    /// Filled in to start with.
    pub default_value: Option<String>,
    /// Substituted without shell quoting.
    pub raw: bool,
}

/// Where a workflow lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum WorkflowScope {
    /// `~/.config/<product>/workflows`.
    Global,
    /// `<repository>/.<product>/workflows`.
    Repo,
}

/// The workflows a pane can use.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkflowList {
    /// Compare with `WorkflowsChanged`.
    pub rev: u64,
    /// The pane's repository (its worktree's top level).
    pub repo: Option<String>,
    /// The repository's name.
    pub repo_name: Option<String>,
    /// The repository's first, then the global ones, each by name.
    pub workflows: Vec<Workflow>,
    /// Files that could not be read.
    pub problems: Vec<WorkflowProblem>,
}

/// A skipped workflow file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkflowProblem {
    /// The file.
    pub path: String,
    /// Why.
    pub message: String,
}

/// A new workflow to save.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkflowDraft {
    /// The title (also names the file).
    pub name: String,
    /// The command line with `{{name}}` placeholders.
    pub command: String,
    /// What it does.
    pub description: Option<String>,
    /// Tags.
    pub tags: Vec<String>,
    /// Arguments (placeholders not listed get one on reading).
    pub arguments: Vec<WorkflowArgument>,
    /// Shells.
    pub shells: Vec<String>,
}

/// A value typed into the argument form.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkflowValue {
    /// The argument.
    pub name: String,
    /// What was typed.
    pub value: String,
}

impl From<proto::WorkflowScope> for WorkflowScope {
    fn from(s: proto::WorkflowScope) -> Self {
        match s {
            proto::WorkflowScope::Global => Self::Global,
            proto::WorkflowScope::Repo => Self::Repo,
        }
    }
}

impl From<WorkflowScope> for proto::WorkflowScope {
    fn from(s: WorkflowScope) -> Self {
        match s {
            WorkflowScope::Global => Self::Global,
            WorkflowScope::Repo => Self::Repo,
        }
    }
}

impl From<proto::WorkflowArgument> for WorkflowArgument {
    fn from(a: proto::WorkflowArgument) -> Self {
        Self {
            name: a.name,
            description: a.description,
            default_value: a.default_value,
            raw: a.raw,
        }
    }
}

impl From<WorkflowArgument> for proto::WorkflowArgument {
    fn from(a: WorkflowArgument) -> Self {
        Self {
            name: a.name,
            description: a.description,
            default_value: a.default_value,
            raw: a.raw,
        }
    }
}

impl From<proto::Workflow> for Workflow {
    fn from(w: proto::Workflow) -> Self {
        Self {
            id: w.id,
            name: w.name,
            command: w.command,
            description: w.description,
            tags: w.tags,
            arguments: w.arguments.into_iter().map(Into::into).collect(),
            shells: w.shells,
            author: w.author,
            source_url: w.source_url,
            scope: w.scope.into(),
            path: w.path,
        }
    }
}

impl From<proto::WorkflowList> for WorkflowList {
    fn from(l: proto::WorkflowList) -> Self {
        Self {
            rev: l.rev,
            repo: l.repo,
            repo_name: l.repo_name,
            workflows: l.workflows.into_iter().map(Into::into).collect(),
            problems: l
                .problems
                .into_iter()
                .map(|p| WorkflowProblem {
                    path: p.path,
                    message: p.message,
                })
                .collect(),
        }
    }
}

impl From<WorkflowDraft> for proto::WorkflowDraft {
    fn from(d: WorkflowDraft) -> Self {
        Self {
            name: d.name,
            command: d.command,
            description: d.description,
            tags: d.tags,
            arguments: d.arguments.into_iter().map(Into::into).collect(),
            shells: d.shells,
        }
    }
}

/// `command` with its placeholders filled: `values`, else each argument's default, else
/// empty; shell-quoted for where each placeholder sits (unquoted, `'…'`, `"…"`) unless the
/// argument is raw. What the argument form previews and types.
#[uniffi::export]
pub fn workflow_render(
    command: String,
    arguments: Vec<WorkflowArgument>,
    values: Vec<WorkflowValue>,
) -> String {
    let arguments: Vec<proto::WorkflowArgument> = arguments.into_iter().map(Into::into).collect();
    let values: Vec<(&str, &str)> = values
        .iter()
        .map(|v| (v.name.as_str(), v.value.as_str()))
        .collect();
    proto::render(&command, &arguments, &values)
}

/// The distinct `{{name}}` placeholders of `command`, in order.
#[uniffi::export]
pub fn workflow_placeholders(command: String) -> Vec<String> {
    proto::placeholders(&command)
        .into_iter()
        .map(str::to_owned)
        .collect()
}

#[uniffi::export]
impl DaemonClient {
    /// The workflows `pane_id` can use (its repository's, then the global ones); only the
    /// global ones when `nil`.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`].
    pub async fn workflow_list(
        &self,
        pane_id: Option<u64>,
    ) -> Result<WorkflowList, WorkspaceError> {
        self.ws_call(|c| async move { c.workflow_list(pane_id.map(proto::PaneId)).await })
            .await
    }

    /// Writes a new workflow file (in `pane_id`'s repository, or the global directory); the
    /// workflow as saved, with its file in `path`.
    ///
    /// # Errors
    ///
    /// The daemon's [`WorkspaceError`]: `NotFound` when the pane is not in a repository,
    /// `Invalid` for an empty name or command.
    pub async fn workflow_save(
        &self,
        scope: WorkflowScope,
        pane_id: Option<u64>,
        workflow: WorkflowDraft,
    ) -> Result<Workflow, WorkspaceError> {
        let save = proto::WorkflowSave {
            scope: scope.into(),
            pane_id: pane_id.map(proto::PaneId),
            workflow: workflow.into(),
        };
        self.ws_call(|c| async move { c.workflow_save(save).await })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_with_values_and_defaults() {
        let args = vec![
            WorkflowArgument {
                name: "branch".into(),
                description: None,
                default_value: Some("main".into()),
                raw: false,
            },
            WorkflowArgument {
                name: "flags".into(),
                description: None,
                default_value: None,
                raw: true,
            },
        ];
        let out = workflow_render(
            "git log {{flags}} {{branch}}".into(),
            args.clone(),
            vec![WorkflowValue {
                name: "flags".into(),
                value: "--oneline -n 5".into(),
            }],
        );
        assert_eq!(out, "git log --oneline -n 5 main");
        let out = workflow_render(
            "git log {{branch}}".into(),
            args,
            vec![WorkflowValue {
                name: "branch".into(),
                value: "my branch".into(),
            }],
        );
        assert_eq!(out, "git log 'my branch'");
        assert_eq!(
            workflow_placeholders("a {{x}} {{y}} {{x}}".into()),
            ["x", "y"]
        );
    }
}
