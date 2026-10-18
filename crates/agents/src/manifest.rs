//!
//! The format, region names and evaluation semantics are ported from herdr v0.9.5
//! (`src/detect/manifest.rs`, Apache-2.0, see `manifests/LICENSE-herdr`) so its manifests load
//!
//! A manifest is a list of rules. Each rule names a target `state`, a `priority`, a `region` of the
//! screen to look at, and matchers:
//!
//! - `contains`: every needle must occur (case-insensitive);
//! - `regex`: every pattern must match the region;
//! - `line_regex`: every pattern must match some line of the region;
//! - `all` / `any` / `not`: nested gates of the same shape, at most 8 deep.
//!
//! The highest-priority matching rule wins; on a tie the earlier rule wins. If nothing matches,
//! `skip_state_update` (a transcript viewer, a model picker) freezes the current state instead.
//!
//! # Examples
//!
//! ```
//! use agents::{AgentState, Manifest, ScreenInput, ScreenVerdict};
//!
//! let manifest = Manifest::from_toml(r#"
//!     id = "demo"
//!     [[rules]]
//!     id = "dialog"
//!     state = "blocked"
//!     priority = 10
//!     visible_blocker = true
//!     contains = ["allow command?"]
//! "#)?;
//! let verdict = manifest.evaluate(ScreenInput::screen("Allow command? [y/n]"));
//! let ScreenVerdict::State(m) = verdict else { panic!() };
//! assert_eq!(m.state, AgentState::Blocked);
//! assert!(m.is_visible());
//! # Ok::<(), agents::ManifestError>(())
//! ```

use std::fmt;
use std::str::FromStr;

use regex::Regex;
use serde::Deserialize;

use crate::event::{AgentState, Source};

/// The engine version this crate implements. Manifests that need a newer one are rejected.
pub const ENGINE_VERSION: u32 = 3;

const MAX_RULES: usize = 128;
const MAX_GATE_DEPTH: usize = 8;
const MAX_TOTAL_GATES: usize = 512;
const MAX_MATCHERS_PER_GATE: usize = 32;
const MAX_TOTAL_MATCHERS: usize = 1024;
const MAX_MATCHER_CHARS: usize = 512;

/// The text a manifest is evaluated against.
#[derive(Debug, Clone, Copy, Default)]
pub struct ScreenInput<'a> {
    /// The live bottom of the screen as plain text, one row per line. Never the scrolled-back
    /// viewport.
    pub screen: &'a str,
    /// The current terminal title (OSC 0/2).
    pub osc_title: &'a str,
    /// The last OSC 9;4 progress report, without the `9;` prefix (e.g. `4;0`).
    pub osc_progress: &'a str,
}

impl<'a> ScreenInput<'a> {
    /// Creates an input with screen text only.
    pub fn screen(screen: &'a str) -> Self {
        Self {
            screen,
            ..Self::default()
        }
    }
}

/// The result of evaluating a manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScreenVerdict {
    /// An overlay hides the agent's real state; keep whatever state the pane had.
    Freeze {
        /// The rule that matched.
        rule_id: String,
    },
    /// The screen shows a state.
    State(ScreenMatch),
}

/// A state read from the screen or title.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenMatch {
    /// The detected state. Never [`AgentState::Error`].
    pub state: AgentState,
    /// [`Source::Title`] when the rule looked at the title or progress, else [`Source::Screen`].
    pub source: Source,
    /// The matching rule, or `None` for the idle fallback.
    pub rule_id: Option<String>,
    visible: bool,
}

impl ScreenMatch {
    /// Creates a match. `visible` means the rule saw a strong, live UI element for this state
    pub fn new(state: AgentState, source: Source, rule_id: Option<String>, visible: bool) -> Self {
        Self {
            state,
            source,
            rule_id,
            visible,
        }
    }

    /// Returns whether the state is backed by a visible UI element. Only visible matches may
    /// override hook claims during arbitration.
    pub fn is_visible(&self) -> bool {
        self.visible
    }
}

/// An error loading a manifest.
#[derive(Debug)]
#[non_exhaustive]
pub enum ManifestError {
    /// The TOML did not parse or had unknown fields.
    Toml(toml::de::Error),
    /// The manifest needs a newer engine than [`ENGINE_VERSION`].
    EngineTooOld {
        /// The version the manifest requires.
        required: u32,
    },
    /// A rule or the manifest broke a structural rule or a size limit.
    Invalid {
        /// The offending rule, if any.
        rule: Option<String>,
        /// What is wrong.
        reason: String,
    },
    /// A pattern is not a valid regex.
    Regex {
        /// The offending rule.
        rule: String,
        /// The compiler error.
        source: regex::Error,
    },
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Toml(err) => write!(f, "manifest is not valid TOML: {err}"),
            Self::EngineTooOld { required } => write!(
                f,
                "manifest needs engine version {required}, this build has {ENGINE_VERSION}"
            ),
            Self::Invalid {
                rule: Some(rule),
                reason,
            } => write!(f, "rule {rule}: {reason}"),
            Self::Invalid { rule: None, reason } => f.write_str(reason),
            Self::Regex { rule, source } => write!(f, "rule {rule}: invalid regex: {source}"),
        }
    }
}

impl std::error::Error for ManifestError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Toml(err) => Some(err),
            Self::Regex { source, .. } => Some(source),
            _ => None,
        }
    }
}

/// A part of the screen a rule looks at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Region {
    /// The whole input screen.
    WholeRecent,
    /// The screen if it has no current Codex prompt (`›`), else nothing.
    WholeRecentWithoutCurrentPromptMarker,
    /// Everything after the last Codex prompt line.
    AfterLastPromptMarker,
    /// Everything before the current Codex prompt line.
    BeforeCurrentPromptMarker,
    /// The last Codex block marker line (`•`, `■`, `✗`, `✓`) before the current prompt.
    CurrentPromptBlockMarker,
    /// From that block marker to the end.
    AfterCurrentPromptBlockMarker,
    /// The lines between the last two horizontal rules (Claude's prompt box).
    PromptBoxBody,
    /// Everything above the prompt box.
    AbovePromptBox,
    /// The last non-empty line above the prompt box.
    LastNonEmptyAbovePromptBox,
    /// Everything after the last horizontal rule.
    AfterLastHorizontalRule,
    /// The terminal title.
    OscTitle,
    /// The OSC 9;4 progress report.
    OscProgress,
    /// The last N lines.
    BottomLines(usize),
    /// From the Nth-last non-empty line to the end.
    BottomNonEmptyLines(usize),
    /// Up to and including the Nth non-empty line. Needs engine version 3.
    TopNonEmptyLines(usize),
}

impl FromStr for Region {
    type Err = String;

    fn from_str(spec: &str) -> Result<Self, Self::Err> {
        let spec = spec.trim();
        let fixed = match spec {
            "whole_recent" => Some(Self::WholeRecent),
            "whole_recent_without_current_prompt_marker" => {
                Some(Self::WholeRecentWithoutCurrentPromptMarker)
            }
            "after_last_prompt_marker" => Some(Self::AfterLastPromptMarker),
            "before_current_prompt_marker" => Some(Self::BeforeCurrentPromptMarker),
            "current_prompt_block_marker" => Some(Self::CurrentPromptBlockMarker),
            "after_current_prompt_block_marker" => Some(Self::AfterCurrentPromptBlockMarker),
            "prompt_box_body" => Some(Self::PromptBoxBody),
            "above_prompt_box" => Some(Self::AbovePromptBox),
            "last_non_empty_above_prompt_box" => Some(Self::LastNonEmptyAbovePromptBox),
            "after_last_horizontal_rule" => Some(Self::AfterLastHorizontalRule),
            "osc_title" => Some(Self::OscTitle),
            "osc_progress" => Some(Self::OscProgress),
            _ => None,
        };
        if let Some(region) = fixed {
            return Ok(region);
        }
        let counted = |name: &str| -> Option<usize> {
            let count = spec
                .strip_prefix(name)?
                .strip_prefix('(')?
                .strip_suffix(')')?;
            if count.is_empty()
                || count.starts_with('0')
                || !count.bytes().all(|b| b.is_ascii_digit())
            {
                return None;
            }
            count.parse().ok().filter(|&n| n <= usize::from(u16::MAX))
        };
        counted("bottom_lines")
            .map(Self::BottomLines)
            .or_else(|| counted("bottom_non_empty_lines").map(Self::BottomNonEmptyLines))
            .or_else(|| counted("top_non_empty_lines").map(Self::TopNonEmptyLines))
            .ok_or_else(|| format!("unknown region {spec:?}"))
    }
}

impl Region {
    fn source(self) -> Source {
        match self {
            Self::OscTitle | Self::OscProgress => Source::Title,
            _ => Source::Screen,
        }
    }

    fn slice<'a>(self, input: &ScreenInput<'a>) -> &'a str {
        let content = input.screen;
        match self {
            Self::OscTitle => input.osc_title,
            Self::OscProgress => input.osc_progress,
            Self::WholeRecent => content,
            Self::WholeRecentWithoutCurrentPromptMarker => {
                let lines: Vec<&str> = content.lines().collect();
                if current_codex_prompt_index(&lines).is_some() {
                    ""
                } else {
                    content
                }
            }
            Self::AfterLastPromptMarker => {
                let lines: Vec<&str> = content.lines().collect();
                match lines.iter().rposition(|line| codex_prompt_line(line)) {
                    Some(index) => slice_from_line(content, &lines, index + 1),
                    None => content,
                }
            }
            Self::BeforeCurrentPromptMarker => {
                let lines: Vec<&str> = content.lines().collect();
                match current_codex_prompt_index(&lines) {
                    Some(index) => &content[..line_start(content, &lines, index)],
                    None => content,
                }
            }
            Self::CurrentPromptBlockMarker => {
                let lines: Vec<&str> = content.lines().collect();
                current_codex_prompt_index(&lines)
                    .and_then(|prompt| {
                        lines[..prompt]
                            .iter()
                            .rev()
                            .find(|line| codex_block_marker_line(line))
                            .copied()
                    })
                    .unwrap_or("")
            }
            Self::AfterCurrentPromptBlockMarker => {
                let lines: Vec<&str> = content.lines().collect();
                current_codex_prompt_index(&lines)
                    .and_then(|prompt| {
                        lines[..prompt]
                            .iter()
                            .rposition(|line| codex_block_marker_line(line))
                    })
                    .map_or("", |block| slice_from_line(content, &lines, block))
            }
            Self::PromptBoxBody => {
                let lines: Vec<&str> = content.lines().collect();
                let Some(top) = prompt_box_top_border(&lines) else {
                    return "";
                };
                let end = lines[top + 1..]
                    .iter()
                    .position(|line| is_horizontal_rule(line))
                    .map_or(lines.len(), |rel| top + 1 + rel);
                &content[line_start(content, &lines, top + 1)..line_start(content, &lines, end)]
            }
            Self::AbovePromptBox => above_prompt_box(content),
            Self::LastNonEmptyAbovePromptBox => above_prompt_box(content)
                .lines()
                .rev()
                .find(|line| !line.trim().is_empty())
                .unwrap_or(""),
            Self::AfterLastHorizontalRule => {
                let mut last_rule_end = 0;
                let mut offset = 0;
                for line in content.lines() {
                    let next = offset + line.len() + 1;
                    if is_horizontal_rule(line) {
                        last_rule_end = next.min(content.len());
                    }
                    offset = next;
                }
                &content[last_rule_end..]
            }
            Self::BottomLines(count) => {
                let lines: Vec<&str> = content.lines().collect();
                slice_from_line(content, &lines, lines.len().saturating_sub(count))
            }
            Self::BottomNonEmptyLines(count) => {
                let lines: Vec<&str> = content.lines().collect();
                lines
                    .iter()
                    .enumerate()
                    .rev()
                    .filter(|(_, line)| !line.trim().is_empty())
                    .take(count)
                    .last()
                    .map_or("", |(index, _)| slice_from_line(content, &lines, index))
            }
            Self::TopNonEmptyLines(count) => {
                let lines: Vec<&str> = content.lines().collect();
                lines
                    .iter()
                    .enumerate()
                    .filter(|(_, line)| !line.trim().is_empty())
                    .take(count)
                    .last()
                    .map_or("", |(index, _)| {
                        &content[..line_start(content, &lines, index + 1)]
                    })
            }
        }
    }
}

// `str::lines` strips `\r\n` as well as `\n`, so offsets assume `\n`-only input; screen text from
// the terminal model is built that way. `min` keeps a missing final newline in bounds.
fn line_start(content: &str, lines: &[&str], index: usize) -> usize {
    lines[..index.min(lines.len())]
        .iter()
        .map(|line| line.len() + 1)
        .sum::<usize>()
        .min(content.len())
}

fn slice_from_line<'a>(content: &'a str, lines: &[&str], index: usize) -> &'a str {
    &content[line_start(content, lines, index)..]
}

fn codex_prompt_line(line: &str) -> bool {
    line == "›" || line.starts_with("› ")
}

fn codex_block_marker_line(line: &str) -> bool {
    line.starts_with(['•', '■', '✗', '✓'])
}

fn current_codex_prompt_index(lines: &[&str]) -> Option<usize> {
    let prompt = lines.iter().rposition(|line| codex_prompt_line(line))?;
    // A response block after the prompt means the prompt is history, not the live input line.
    (!lines[prompt + 1..]
        .iter()
        .any(|line| codex_block_marker_line(line)))
    .then_some(prompt)
}

fn prompt_box_top_border(lines: &[&str]) -> Option<usize> {
    lines
        .iter()
        .enumerate()
        .rev()
        .filter(|(_, line)| is_horizontal_rule(line))
        .nth(1)
        .map(|(index, _)| index)
}

fn above_prompt_box(content: &str) -> &str {
    let lines: Vec<&str> = content.lines().collect();
    match prompt_box_top_border(&lines) {
        Some(top) => &content[..line_start(content, &lines, top)],
        None => content,
    }
}

fn is_horizontal_rule(line: &str) -> bool {
    let trimmed = line.trim();
    let rule_chars = trimmed.chars().take_while(|&c| c == '─').count();
    if rule_chars == 0 {
        return false;
    }
    // A rule may carry a label (Claude's named-session divider) only if it is a real run of rule
    // characters, not a stray box glyph.
    let suffix = trimmed['─'.len_utf8() * rule_chars..].trim_start();
    suffix.is_empty() || rule_chars >= 3
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RuleState {
    Idle,
    Working,
    Blocked,
    Unknown,
}

impl From<RuleState> for AgentState {
    fn from(state: RuleState) -> Self {
        match state {
            RuleState::Idle => Self::Idle,
            RuleState::Working => Self::Working,
            RuleState::Blocked => Self::Blocked,
            RuleState::Unknown => Self::Unknown,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawManifest {
    id: String,
    version: Option<String>,
    min_engine_version: Option<u32>,
    #[serde(rename = "updated_at")]
    _updated_at: Option<String>,
    #[serde(default)]
    aliases: Vec<String>,
    #[serde(default)]
    rules: Vec<RawRule>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawRule {
    id: String,
    state: Option<RuleState>,
    #[serde(default)]
    priority: i32,
    #[serde(default = "default_region")]
    region: String,
    #[serde(default)]
    visible_idle: bool,
    #[serde(default)]
    visible_blocker: bool,
    #[serde(default)]
    visible_working: bool,
    #[serde(default)]
    skip_state_update: bool,
    // The rule is itself the top-level gate. These fields are spelled out rather than flattened
    // because serde cannot combine `flatten` with `deny_unknown_fields`.
    #[serde(default)]
    all: Vec<RawGate>,
    #[serde(default)]
    any: Vec<RawGate>,
    #[serde(default)]
    not: Vec<RawGate>,
    #[serde(default)]
    contains: Vec<String>,
    #[serde(default)]
    regex: Vec<String>,
    #[serde(default)]
    line_regex: Vec<String>,
}

impl RawRule {
    fn take_gate(&mut self) -> RawGate {
        RawGate {
            all: std::mem::take(&mut self.all),
            any: std::mem::take(&mut self.any),
            not: std::mem::take(&mut self.not),
            contains: std::mem::take(&mut self.contains),
            regex: std::mem::take(&mut self.regex),
            line_regex: std::mem::take(&mut self.line_regex),
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawGate {
    #[serde(default)]
    all: Vec<RawGate>,
    #[serde(default)]
    any: Vec<RawGate>,
    #[serde(default)]
    not: Vec<RawGate>,
    #[serde(default)]
    contains: Vec<String>,
    #[serde(default)]
    regex: Vec<String>,
    #[serde(default)]
    line_regex: Vec<String>,
}

fn default_region() -> String {
    "whole_recent".to_owned()
}

#[derive(Debug, Clone)]
struct Gate {
    all: Vec<Gate>,
    any: Vec<Gate>,
    not: Vec<Gate>,
    /// Lowercased needles.
    contains: Vec<String>,
    regex: Vec<Regex>,
    line_regex: Vec<Regex>,
}

impl Gate {
    fn matches(&self, text: &str, lower: &str) -> bool {
        self.contains
            .iter()
            .all(|needle| lower.contains(needle.as_str()))
            && self.regex.iter().all(|re| re.is_match(text))
            && self
                .line_regex
                .iter()
                .all(|re| text.lines().any(|line| re.is_match(line)))
            && self.all.iter().all(|gate| gate.matches(text, lower))
            && (self.any.is_empty() || self.any.iter().any(|gate| gate.matches(text, lower)))
            && !self.not.iter().any(|gate| gate.matches(text, lower))
    }
}

#[derive(Debug, Clone)]
struct Rule {
    id: String,
    state: AgentState,
    priority: i32,
    region: Region,
    visible: bool,
    skip_state_update: bool,
    gate: Gate,
}

/// A compiled screen-detection manifest for one agent.
#[derive(Debug, Clone)]
pub struct Manifest {
    id: String,
    version: Option<String>,
    aliases: Vec<String>,
    rules: Vec<Rule>,
}

#[derive(Default)]
struct Budget {
    gates: usize,
    matchers: usize,
}

impl Manifest {
    /// Parses, validates and compiles a manifest.
    ///
    /// # Errors
    ///
    /// Returns [`ManifestError`] if the TOML is malformed or has unknown fields, the manifest
    /// needs a newer engine, a region is unknown, a limit is exceeded (128 rules, 512 gates,
    /// 1024 matchers, 32 matchers per gate, 512 characters per matcher, gate depth 8), a rule has
    /// no positive matcher, or a regex does not compile.
    pub fn from_toml(text: &str) -> Result<Self, ManifestError> {
        let raw: RawManifest = toml::from_str(text).map_err(ManifestError::Toml)?;
        let invalid = |rule: Option<&str>, reason: String| ManifestError::Invalid {
            rule: rule.map(str::to_owned),
            reason,
        };
        if raw.id.trim().is_empty() {
            return Err(invalid(None, "manifest id is empty".into()));
        }
        if let Some(required) = raw.min_engine_version.filter(|&v| v > ENGINE_VERSION) {
            return Err(ManifestError::EngineTooOld { required });
        }
        if raw.rules.len() > MAX_RULES {
            return Err(invalid(None, format!("more than {MAX_RULES} rules")));
        }

        let mut budget = Budget::default();
        let mut rules = Vec::with_capacity(raw.rules.len());
        for mut rule in raw.rules {
            let raw_gate = rule.take_gate();
            let id = rule.id.as_str();
            if id.trim().is_empty() {
                return Err(invalid(None, "rule id is empty".into()));
            }
            let region: Region = rule.region.parse().map_err(|e| invalid(Some(id), e))?;
            if matches!(region, Region::TopNonEmptyLines(_))
                && raw.min_engine_version.unwrap_or(0) < 3
            {
                return Err(invalid(
                    Some(id),
                    "top_non_empty_lines needs min_engine_version >= 3".into(),
                ));
            }
            if !has_positive_matcher(&raw_gate) {
                return Err(invalid(Some(id), "rule has no positive matcher".into()));
            }
            let gate = compile_gate(&raw_gate, id, 1, &mut budget)?;
            let state = rule.state.map_or(AgentState::Unknown, AgentState::from);
            let visible = match state {
                AgentState::Idle => rule.visible_idle,
                AgentState::Working => rule.visible_working,
                AgentState::Blocked => rule.visible_blocker,
                AgentState::Error | AgentState::Unknown => false,
            };
            rules.push(Rule {
                id: rule.id,
                state,
                priority: rule.priority,
                region,
                visible,
                skip_state_update: rule.skip_state_update,
                gate,
            });
        }

        Ok(Self {
            id: raw.id,
            version: raw.version,
            aliases: raw.aliases,
            rules,
        })
    }

    /// Returns the manifest's agent id, e.g. `claude`.
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Returns the manifest version, e.g. `2026.10.11.1`.
    pub fn version(&self) -> Option<&str> {
        self.version.as_deref()
    }

    /// Returns alternative agent names, e.g. `claude-code`.
    pub fn aliases(&self) -> &[String] {
        &self.aliases
    }

    /// Evaluates the rules against a screen and returns the winning verdict.
    pub fn evaluate(&self, input: ScreenInput<'_>) -> ScreenVerdict {
        let mut best: Option<&Rule> = None;
        for rule in &self.rules {
            if best.is_some_and(|b| b.priority >= rule.priority) {
                continue;
            }
            let text = rule.region.slice(&input);
            if rule.gate.matches(text, &text.to_lowercase()) {
                best = Some(rule);
            }
        }
        match best {
            Some(rule) if rule.skip_state_update => ScreenVerdict::Freeze {
                rule_id: rule.id.clone(),
            },
            Some(rule) => ScreenVerdict::State(ScreenMatch::new(
                rule.state,
                rule.region.source(),
                Some(rule.id.clone()),
                rule.visible,
            )),
            None => ScreenVerdict::State(ScreenMatch::new(
                AgentState::Idle,
                Source::Screen,
                None,
                false,
            )),
        }
    }
}

fn has_positive_matcher(gate: &RawGate) -> bool {
    !gate.contains.is_empty()
        || !gate.regex.is_empty()
        || !gate.line_regex.is_empty()
        || gate.all.iter().any(has_positive_matcher)
        || gate.any.iter().any(has_positive_matcher)
}

fn compile_gate(
    raw: &RawGate,
    rule: &str,
    depth: usize,
    budget: &mut Budget,
) -> Result<Gate, ManifestError> {
    let invalid = |reason: String| ManifestError::Invalid {
        rule: Some(rule.to_owned()),
        reason,
    };
    if depth > MAX_GATE_DEPTH {
        return Err(invalid(format!("gates nest deeper than {MAX_GATE_DEPTH}")));
    }
    budget.gates += 1;
    if budget.gates > MAX_TOTAL_GATES {
        return Err(invalid(format!("more than {MAX_TOTAL_GATES} gates")));
    }
    let matchers = raw.contains.len() + raw.regex.len() + raw.line_regex.len();
    if matchers > MAX_MATCHERS_PER_GATE {
        return Err(invalid(format!(
            "more than {MAX_MATCHERS_PER_GATE} matchers in one gate"
        )));
    }
    budget.matchers += matchers;
    if budget.matchers > MAX_TOTAL_MATCHERS {
        return Err(invalid(format!("more than {MAX_TOTAL_MATCHERS} matchers")));
    }
    let all_patterns = raw.contains.iter().chain(&raw.regex).chain(&raw.line_regex);
    if let Some(long) = all_patterns
        .into_iter()
        .find(|p| p.chars().count() > MAX_MATCHER_CHARS)
    {
        return Err(invalid(format!(
            "matcher longer than {MAX_MATCHER_CHARS} characters: {:.40}…",
            long
        )));
    }
    let compile = |patterns: &[String]| -> Result<Vec<Regex>, ManifestError> {
        patterns
            .iter()
            .map(|p| {
                Regex::new(p).map_err(|source| ManifestError::Regex {
                    rule: rule.to_owned(),
                    source,
                })
            })
            .collect()
    };
    let nested = |gates: &[RawGate], budget: &mut Budget| -> Result<Vec<Gate>, ManifestError> {
        gates
            .iter()
            .map(|g| compile_gate(g, rule, depth + 1, budget))
            .collect()
    };
    Ok(Gate {
        all: nested(&raw.all, budget)?,
        any: nested(&raw.any, budget)?,
        not: nested(&raw.not, budget)?,
        contains: raw.contains.iter().map(|n| n.to_lowercase()).collect(),
        regex: compile(&raw.regex)?,
        line_regex: compile(&raw.line_regex)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(verdict: ScreenVerdict) -> (AgentState, Option<String>, bool) {
        match verdict {
            ScreenVerdict::State(m) => (m.state, m.rule_id.clone(), m.is_visible()),
            ScreenVerdict::Freeze { rule_id } => panic!("unexpected freeze by {rule_id}"),
        }
    }

    #[test]
    fn regions_parse() {
        assert_eq!("bottom_lines(5)".parse(), Ok(Region::BottomLines(5)));
        assert_eq!(
            " bottom_non_empty_lines(12) ".parse(),
            Ok(Region::BottomNonEmptyLines(12))
        );
        assert_eq!(
            "top_non_empty_lines(20)".parse(),
            Ok(Region::TopNonEmptyLines(20))
        );
        assert!("top_non_empty_lines(0)".parse::<Region>().is_err());
        assert!("bottom_lines(x)".parse::<Region>().is_err());
        assert!("middle".parse::<Region>().is_err());
    }

    #[test]
    fn higher_priority_wins_and_ties_keep_the_first() {
        let manifest = Manifest::from_toml(
            r#"
            id = "t"
            [[rules]]
            id = "low"
            state = "working"
            priority = 1
            contains = ["x"]
            [[rules]]
            id = "high"
            state = "blocked"
            priority = 5
            contains = ["x"]
            [[rules]]
            id = "tie"
            state = "idle"
            priority = 5
            contains = ["x"]
            "#,
        )
        .unwrap();
        let (s, rule, _) = state(manifest.evaluate(ScreenInput::screen("X")));
        assert_eq!(s, AgentState::Blocked);
        assert_eq!(rule.as_deref(), Some("high"));
    }

    #[test]
    fn falls_back_to_invisible_idle() {
        let manifest = Manifest::from_toml(
            r#"
            id = "t"
            [[rules]]
            id = "r"
            state = "working"
            contains = ["spinner"]
            "#,
        )
        .unwrap();
        assert_eq!(
            state(manifest.evaluate(ScreenInput::screen("$ "))),
            (AgentState::Idle, None, false)
        );
    }

    #[test]
    fn gates_combine() {
        let manifest = Manifest::from_toml(
            r#"
            id = "t"
            [[rules]]
            id = "r"
            state = "blocked"
            priority = 1
            contains = ["proceed?"]
            all = [{ any = [{ line_regex = ['(?i)^\s*1\. yes'] }, { contains = ["[y/n]"] }] }]
            not = [{ contains = ["transcript"] }]
            "#,
        )
        .unwrap();
        let blocked = |s| state(manifest.evaluate(ScreenInput::screen(s))).0;
        assert_eq!(blocked("Proceed?\n  1. Yes\n  2. No"), AgentState::Blocked);
        assert_eq!(blocked("Proceed? [y/n]"), AgentState::Blocked);
        assert_eq!(blocked("Proceed?\nmaybe"), AgentState::Idle);
        assert_eq!(blocked("Proceed? [y/n] transcript"), AgentState::Idle);
    }

    #[test]
    fn title_rules_report_the_title_source() {
        let manifest = Manifest::from_toml(
            r#"
            id = "t"
            [[rules]]
            id = "title"
            state = "blocked"
            priority = 1
            region = "osc_title"
            visible_blocker = true
            contains = ["Action Required"]
            "#,
        )
        .unwrap();
        let verdict = manifest.evaluate(ScreenInput {
            screen: "",
            osc_title: "[ ! ] Action Required",
            osc_progress: "",
        });
        let ScreenVerdict::State(m) = verdict else {
            panic!()
        };
        assert_eq!(
            (m.state, m.source, m.is_visible()),
            (AgentState::Blocked, Source::Title, true)
        );
    }

    #[test]
    fn skip_state_update_freezes() {
        let manifest = Manifest::from_toml(
            r#"
            id = "t"
            [[rules]]
            id = "viewer"
            state = "unknown"
            priority = 1
            skip_state_update = true
            contains = ["showing detailed transcript"]
            "#,
        )
        .unwrap();
        assert_eq!(
            manifest.evaluate(ScreenInput::screen("Showing detailed transcript")),
            ScreenVerdict::Freeze {
                rule_id: "viewer".into()
            }
        );
    }

    #[test]
    fn rejects_bad_manifests() {
        let err = |toml: &str| Manifest::from_toml(toml).unwrap_err();
        assert!(matches!(
            err("id = \"t\"\nbogus = 1"),
            ManifestError::Toml(_)
        ));
        assert!(matches!(
            err("id = \"t\"\nmin_engine_version = 99"),
            ManifestError::EngineTooOld { required: 99 }
        ));
        assert!(matches!(
            err("id = \"t\"\n[[rules]]\nid = \"r\"\nregion = \"nowhere\"\ncontains = [\"x\"]"),
            ManifestError::Invalid { .. }
        ));
        assert!(matches!(
            err("id = \"t\"\n[[rules]]\nid = \"r\"\nnot = [{ contains = [\"x\"] }]"),
            ManifestError::Invalid { .. }
        ));
        assert!(matches!(
            err("id = \"t\"\n[[rules]]\nid = \"r\"\nregex = ['(']"),
            ManifestError::Regex { .. }
        ));
        assert!(matches!(
            err(
                "id = \"t\"\n[[rules]]\nid = \"r\"\nregion = \"top_non_empty_lines(3)\"\ncontains = [\"x\"]"
            ),
            ManifestError::Invalid { .. }
        ));
        let deep = format!(
            "id = \"t\"\n[[rules]]\nid = \"r\"\nall = [{}{{ contains = [\"x\"] }}{}]",
            "{ all = [".repeat(9),
            "] }".repeat(9)
        );
        assert!(matches!(err(&deep), ManifestError::Invalid { .. }));
    }

    #[test]
    fn prompt_box_regions() {
        let screen = "output\nlast words\n────────\n❯ hello\n────────\n  ? for shortcuts";
        let input = ScreenInput::screen(screen);
        assert_eq!(Region::PromptBoxBody.slice(&input), "❯ hello\n");
        assert_eq!(Region::AbovePromptBox.slice(&input), "output\nlast words\n");
        assert_eq!(
            Region::LastNonEmptyAbovePromptBox.slice(&input),
            "last words"
        );
        assert_eq!(
            Region::AfterLastHorizontalRule.slice(&input),
            "  ? for shortcuts"
        );
    }

    #[test]
    fn codex_prompt_regions() {
        let screen = "• Ran tests\n• Working (3s • esc to interrupt)\n› fix it\n  ctx 40%";
        let input = ScreenInput::screen(screen);
        assert_eq!(
            Region::BeforeCurrentPromptMarker.slice(&input),
            "• Ran tests\n• Working (3s • esc to interrupt)\n"
        );
        assert_eq!(Region::AfterLastPromptMarker.slice(&input), "  ctx 40%");
        assert_eq!(
            Region::CurrentPromptBlockMarker.slice(&input),
            "• Working (3s • esc to interrupt)"
        );
        assert_eq!(
            Region::WholeRecentWithoutCurrentPromptMarker.slice(&input),
            ""
        );
        let stale = ScreenInput::screen("› old prompt\n• answer");
        assert_eq!(
            Region::WholeRecentWithoutCurrentPromptMarker.slice(&stale),
            "› old prompt\n• answer"
        );
    }

    #[test]
    fn line_window_regions() {
        let input = ScreenInput::screen("a\n\nb\nc\n\n");
        assert_eq!(Region::BottomLines(2).slice(&input), "c\n\n");
        assert_eq!(Region::BottomNonEmptyLines(2).slice(&input), "b\nc\n\n");
        assert_eq!(Region::TopNonEmptyLines(2).slice(&input), "a\n\nb\n");
    }
}
