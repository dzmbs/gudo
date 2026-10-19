//! Per-prompt state kept next to a pane's command log: which prompt instance is up, where its
//! input starts when the shell does not say (fish 3), whether a continuation prompt is up, and
//! the right prompt drawn with it.
//!
//! Updated from the output hook (under the VT lock) as OSC 133 events arrive; read by
//! [`super::line`] to extract the input line.

use std::time::{Duration, Instant};

use ghostty_vt::{CellWidth, PinId, Point, Terminal};

/// What the shell is doing, as far as its marks tell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum Phase {
    /// No prompt seen yet (no shell integration, or not started).
    #[default]
    Idle,
    /// A prompt is up and the user edits its command line.
    Prompt,
    /// Command `id` runs.
    Running(u64),
    /// The last command finished; the next prompt is not drawn yet.
    Finished,
}

/// Text drawn at the right edge of the prompt's first row when it appeared (zsh `RPROMPT`,
/// fish `fish_right_prompt`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RightPrompt {
    /// First column.
    pub col: u16,
    /// The cells' text, one entry per cell (spacers included as empty strings).
    pub cells: Vec<String>,
}

#[derive(Debug, Default)]
pub(crate) struct LineMarks {
    phase: Phase,
    /// A continuation prompt (PS2) followed the input start.
    pub continuation: bool,
    /// Where input starts when the shell sent no `133;B`: the cursor once the prompt was drawn.
    inferred: Option<PinId>,
    right_prompt: Option<RightPrompt>,
    /// When `inferred` was first set: output in the next moments is still the prompt.
    inferred_at: Option<Instant>,
    /// The cursor has stayed at the input start since it was marked: text drawn after a gap
    /// on that row is the right prompt.
    watch_right: bool,
    prompt_in_batch: bool,
    input_in_batch: bool,
}

/// How long after `133;A` output still counts as prompt for shells without `133;B`.
const INFER_WINDOW: Duration = Duration::from_millis(25);

/// A copy of the marks for one read of the input line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LineView {
    pub phase: Phase,
    /// Changes whenever a command starts.
    pub prompt_id: u64,
    /// Where input starts (the `133;B` pin, else the inferred one).
    pub input: Option<PinId>,
    /// `input` was inferred, not marked.
    pub inferred: bool,
    pub continuation: bool,
    pub right_prompt: Option<RightPrompt>,
}

impl LineMarks {
    /// `133;A`: a primary prompt starts (a new one, or a redraw of the current one).
    pub fn prompt_started(&mut self, term: &mut Terminal) {
        if self.phase != Phase::Prompt {
            // A new prompt instance; a redraw keeps the right prompt seen with the first draw.
            self.right_prompt = None;
        }
        self.phase = Phase::Prompt;
        self.continuation = false;
        self.prompt_in_batch = true;
        self.drop_inferred(term);
    }

    /// `133;B`.
    pub fn input_started(&mut self, term: &mut Terminal) {
        self.input_in_batch = true;
        if self.phase != Phase::Prompt {
            // Shells that only mark input (`zle-line-init` fallback) are at a prompt now.
            self.phase = Phase::Prompt;
        }
        self.drop_inferred(term);
    }

    /// `133;C`: command `id` starts.
    pub fn output_started(&mut self, term: &mut Terminal, id: u64) {
        self.phase = Phase::Running(id);
        self.watch_right = false;
        self.continuation = false;
        self.drop_inferred(term);
    }

    /// `133;D` of a running command.
    pub fn command_ended(&mut self) {
        self.phase = Phase::Finished;
    }

    /// After a batch of events, once the bytes that carried them are on screen: infer the
    /// input start for shells without `133;B`, and remember the right prompt.
    pub fn after_batch(
        &mut self,
        term: &mut Terminal,
        prompt: Option<PinId>,
        input: Option<PinId>,
    ) {
        let (prompt_in_batch, input_in_batch) = (self.prompt_in_batch, self.input_in_batch);
        self.prompt_in_batch = false;
        self.input_in_batch = false;
        if self.phase != Phase::Prompt {
            return;
        }
        if input.is_none() && prompt.is_some() && prompt_in_batch {
            // fish 3: once the prompt is drawn the cursor sits where input starts. The prompt
            // may arrive in a few reads, so `after_output` follows it for a moment.
            self.inferred_at = Some(Instant::now());
            self.repin_inferred(term);
            self.watch_right = true;
        } else if input_in_batch && input.is_some() {
            self.inferred_at = None;
            self.watch_right = true;
        }
        self.after_output(term, input);
    }

    /// After any output while a prompt is up: follows the inferred input start while the
    /// prompt is drawn, and remembers a right prompt drawn while the cursor waits at the input
    /// start.
    pub fn after_output(&mut self, term: &mut Terminal, input: Option<PinId>) {
        if self.phase != Phase::Prompt {
            return;
        }
        if input.is_none() && self.inferred_at.is_some_and(|t| t.elapsed() < INFER_WINDOW) {
            self.repin_inferred(term);
        }
        if !self.watch_right {
            return;
        }
        let Some(start) = input.or(self.inferred).and_then(|p| term.pin_point(p)) else {
            self.watch_right = false;
            return;
        };
        if term.cursor_point() != start {
            self.watch_right = false;
            return;
        }
        if let Some(rp) = right_prompt_after(term, start) {
            self.right_prompt = Some(rp);
        }
    }

    fn drop_inferred(&mut self, term: &mut Terminal) {
        self.inferred_at = None;
        if let Some(pin) = self.inferred.take() {
            term.unpin(pin);
        }
    }

    fn repin_inferred(&mut self, term: &mut Terminal) {
        if let Ok(pin) = term.pin_cursor()
            && let Some(old) = self.inferred.replace(pin)
        {
            term.unpin(old);
        }
    }

    /// Cuts the remembered right prompt off a command line read off the screen (zsh leaves
    /// `RPROMPT` on the line when it runs it).
    pub fn strip_right_prompt(&self, text: &str) -> String {
        let Some(rp) = &self.right_prompt else {
            return text.to_owned();
        };
        let rp_text = rp.cells.concat();
        let rp_text = rp_text.trim();
        let (first, rest) = match text.split_once('\n') {
            Some((first, rest)) => (first, Some(rest)),
            None => (text, None),
        };
        let first = match first.trim_end().strip_suffix(rp_text) {
            Some(kept) if !rp_text.is_empty() && kept.ends_with(' ') => kept.trim_end(),
            _ => first,
        };
        match rest {
            Some(rest) => format!("{first}\n{rest}"),
            None => first.to_owned(),
        }
    }

    /// The inferred input start, for shells that send no `133;B`.
    pub fn inferred(&self) -> Option<PinId> {
        self.inferred
    }

    pub fn view(&self, prompt: Option<PinId>, input: Option<PinId>, prompt_id: u64) -> LineView {
        let inferred = input.is_none() && prompt.is_some() && self.inferred.is_some();
        LineView {
            phase: self.phase,
            prompt_id,
            input: input.or(if inferred { self.inferred } else { None }),
            inferred,
            continuation: self.continuation,
            right_prompt: self.right_prompt.clone(),
        }
    }
}

/// The text on `start`'s row after a gap, when the line editor has not drawn anything yet
/// (cursor at the input start): that is the right prompt.
fn right_prompt_after(term: &Terminal, start: Point) -> Option<RightPrompt> {
    let row = term.row(start.y).ok()?;
    let cells = row.cells.get(usize::from(start.x)..)?;
    // Text right at the cursor is not a right prompt (a pushed buffer, a suggestion).
    if cells.first().is_none_or(|c| !c.is_blank()) {
        return None;
    }
    let first = cells
        .iter()
        .position(|c| !c.is_blank() && c.width != CellWidth::SpacerTail)?;
    let last = cells.iter().rposition(|c| !c.is_blank())?;
    Some(RightPrompt {
        col: start.x + first as u16,
        cells: cells[first..=last].iter().map(|c| c.text.clone()).collect(),
    })
}
