//! Shell-integration command marks (OSC 133) for one pane, kept next to its terminal.
//!
//! Each command gets pins (tracked cells) at its prompt, input, output start and end, so its
//! rows can be found after scrolling, reflow or scrollback pruning, and its output sliced out
//! for "copy output" and link extraction.

use std::collections::VecDeque;
use std::time::Instant;

use ghostty_vt::{
    PinId, Point, PromptKind, SemanticPrompt, SemanticPromptKind, Terminal, TextRegion, Wrap,
};
use proto::{CommandEnd, CommandInfo, CommandMark, CommandRows, PaneId, Seq, UnixMillis};

use crate::identity::now_millis;

/// Commands remembered per pane; older ones are forgotten (and their pins released).
const MAX_COMMANDS: usize = 1000;
/// Longest command line read off the screen.
const MAX_COMMAND_LINE: usize = 4096;
const MAX_CONTINUATIONS: usize = 128;

/// A change worth telling clients about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CommandUpdate {
    /// The cursor entered (`true`, 133;B) or left (`false`, 133;C) a prompt's input area.
    AtPrompt(bool),
    /// A command started or finished.
    Mark(CommandMark),
}

#[derive(Debug)]
struct Command {
    mark: CommandMark,
    /// Typed with leading whitespace (`HISTCONTROL=ignorespace`): kept out of history.
    private: bool,
    started: Instant,
    prompt: Option<PinId>,
    input: Option<PinId>,
    output: Option<PinId>,
    end: Option<PinId>,
}

impl Command {
    fn pins(&self) -> impl Iterator<Item = PinId> {
        [self.prompt, self.input, self.output, self.end]
            .into_iter()
            .flatten()
    }
}

#[derive(Debug, Default)]
pub(crate) struct CommandLog {
    next_id: u64,
    /// Pins of the prompt being drawn or edited, before its command runs.
    prompt: Option<PinId>,
    input: Option<PinId>,
    continuations: Vec<PinId>,
    pending_prompt: Option<PromptKind>,
    continuation_overflow: bool,
    commands: VecDeque<Command>,
    /// The current prompt's input state, for the mobile line editor.
    line: crate::assist::marks::LineMarks,
}

impl CommandLog {
    /// The id the last command got (0 before any).
    pub fn last_id(&self) -> u64 {
        self.next_id
    }

    /// Numbers commands on from `last_id`, the last one a previous daemon build gave out in
    /// this pane, so ids clients hold never name a different command.
    pub fn continue_numbering(&mut self, last_id: u64) {
        self.next_id = self.next_id.max(last_id);
    }

    fn clear_continuations(&mut self, term: &mut Terminal) {
        self.continuations.drain(..).for_each(|pin| term.unpin(pin));
        self.pending_prompt = None;
        self.continuation_overflow = false;
    }

    /// Applies the terminal's recorded shell-integration events. `seq` is the output offset
    /// after the bytes that produced them.
    pub fn apply(
        &mut self,
        term: &mut Terminal,
        pane: PaneId,
        seq: Seq,
        events: Vec<SemanticPrompt>,
    ) -> Vec<CommandUpdate> {
        let mut updates = Vec::new();
        for event in events {
            match event.kind {
                SemanticPromptKind::PromptStart(PromptKind::Primary) => {
                    replace(term, &mut self.prompt, event.pin);
                    replace(term, &mut self.input, None);
                    self.clear_continuations(term);
                    self.pending_prompt = Some(PromptKind::Primary);
                    self.line.prompt_started(term);
                    // Shells that never send 133;B (fish 3) are at their prompt from here.
                    updates.push(CommandUpdate::AtPrompt(true));
                }
                SemanticPromptKind::PromptStart(kind) => {
                    self.pending_prompt = Some(kind);
                    if kind != PromptKind::Right && self.input.is_some() {
                        self.line.continuation = true;
                        if self.continuations.len() < MAX_CONTINUATIONS {
                            if let Some(pin) = event.pin {
                                self.continuations.push(pin);
                            } else {
                                self.continuation_overflow = true;
                            }
                        } else {
                            self.continuation_overflow = true;
                            release(term, event.pin);
                        }
                    } else {
                        release(term, event.pin);
                    }
                }
                SemanticPromptKind::InputStart => {
                    match self.pending_prompt.take() {
                        Some(PromptKind::Right) => {
                            release(term, event.pin);
                            continue;
                        }
                        Some(PromptKind::Continuation | PromptKind::Secondary)
                            if self.input.is_some() =>
                        {
                            // Replace the PS2 start with its input start, excluding prompt glyphs.
                            if !self.continuation_overflow
                                && let Some(last) = self.continuations.last_mut()
                                && let Some(pin) = event.pin
                            {
                                term.unpin(std::mem::replace(last, pin));
                            } else {
                                self.continuation_overflow = true;
                                release(term, event.pin);
                            }
                        }
                        _ => {
                            if self.input.is_some() {
                                // zle-line-init fallback redraw: a fresh B without another A.
                                let prompt = event
                                    .pin
                                    .and_then(|pin| term.pin_point(pin))
                                    .and_then(|point| term.pin_at(point).ok());
                                replace(term, &mut self.prompt, prompt);
                                self.line.prompt_started(term);
                            }
                            self.clear_continuations(term);
                            replace(term, &mut self.input, event.pin);
                        }
                    }
                    self.line.input_started(term);
                    updates.push(CommandUpdate::AtPrompt(true));
                }
                SemanticPromptKind::OutputStart { command } => {
                    let raw = command.or_else(|| self.typed_command(term, event.pin));
                    let private = raw
                        .as_deref()
                        .is_some_and(|line| line.starts_with([' ', '\t']));
                    // `133;C;cmdline=` is forgeable by any program: keep only what prints.
                    let command = raw
                        .map(|line| {
                            let line = crate::term::visible(&line);
                            line.trim()
                                .chars()
                                .take(MAX_COMMAND_LINE)
                                .collect::<String>()
                        })
                        .filter(|line| !line.is_empty());
                    self.next_id += 1;
                    self.clear_continuations(term);
                    self.line.output_started(term, self.next_id);
                    let mark = CommandMark {
                        pane_id: pane,
                        command_id: self.next_id,
                        command,
                        cwd: term.pwd().and_then(|pwd| crate::osc::cwd_path(&pwd)),
                        started_at: UnixMillis(now_millis()),
                        at_seq: seq,
                        finished: None,
                    };
                    updates.push(CommandUpdate::AtPrompt(false));
                    updates.push(CommandUpdate::Mark(mark.clone()));
                    self.commands.push_back(Command {
                        mark,
                        private,
                        started: Instant::now(),
                        prompt: self.prompt.take(),
                        input: self.input.take(),
                        output: event.pin,
                        end: None,
                    });
                    if self.commands.len() > MAX_COMMANDS
                        && let Some(oldest) = self.commands.pop_front()
                    {
                        oldest.pins().for_each(|pin| term.unpin(pin));
                    }
                }
                SemanticPromptKind::CommandEnd { exit } => {
                    match self
                        .commands
                        .back_mut()
                        .filter(|command| command.mark.finished.is_none())
                    {
                        Some(command) => {
                            command.end = event.pin;
                            command.mark.at_seq = seq;
                            command.mark.finished = Some(CommandEnd {
                                exit,
                                duration_ms: command.started.elapsed().as_millis() as u64,
                            });
                            updates.push(CommandUpdate::Mark(command.mark.clone()));
                        }
                        // A prompt without a command (empty Enter, the first prompt).
                        None => release(term, event.pin),
                    }
                    replace(term, &mut self.prompt, None);
                    replace(term, &mut self.input, None);
                    self.clear_continuations(term);
                    self.line.command_ended(term);
                }
            }
        }
        self.line.after_batch(term, self.prompt, self.input);
        updates
    }

    /// Called after every chunk of output (with or without events): tracks the prompt's
    /// input start and right prompt while they are drawn.
    pub fn after_output(&mut self, term: &mut Terminal) {
        self.line.after_output(term, self.input);
    }

    /// The current prompt's marks, for reading the input line.
    pub fn line_marks(&self) -> crate::assist::marks::LineView {
        self.line.view(self.prompt, self.input, self.next_id)
    }

    /// Whether command `id` was typed with a leading space (kept out of history).
    pub fn is_private(&self, id: u64) -> bool {
        self.commands
            .iter()
            .any(|command| command.mark.command_id == id && command.private)
    }

    /// The command line as typed: the cells from the input start to just before `output`.
    fn typed_command(&self, term: &Terminal, output: Option<PinId>) -> Option<String> {
        // Shells without `133;B` (fish 3): from where the cursor was after the prompt.
        let start = term.pin_point(self.input.or(self.line.inferred())?)?;
        let end = before(term, term.pin_point(output?)?)?;
        if end < start {
            return None;
        }
        if self.continuation_overflow {
            return None;
        }
        let mut text = String::new();
        let mut remaining = MAX_COMMAND_LINE;
        let mut x = start.x;
        // A hard newline ends input unless the next row has an explicit PS2 mark. Reading
        // row by row bounds work and never allocates an entire completion listing first.
        for y in (start.y..=end.y).take(MAX_COMMAND_LINE) {
            let row = term.row(y).ok()?;
            let end_x = if y == end.y { end.x } else { term.cols() - 1 };
            let piece = term
                .text_wrapped(
                    TextRegion::Range {
                        start: Point { y, x },
                        end: Point { y, x: end_x },
                    },
                    Wrap::Join,
                )
                .ok()?;
            let piece: String = piece.chars().take(remaining).collect();
            remaining -= piece.chars().count();
            text.push_str(&piece);
            if remaining == 0 || y == end.y {
                break;
            }
            if row.wrapped {
                x = 0;
            } else if let Some(next) = self
                .continuations
                .iter()
                .filter_map(|&pin| term.pin_point(pin))
                .find(|point| point.y == y + 1)
            {
                text.push('\n');
                remaining -= 1;
                x = next.x;
            } else {
                break;
            }
        }
        // Leading whitespace is kept for the history privacy rule; the caller trims.
        Some(self.line.strip_right_prompt(text.trim_end()))
    }

    /// Every remembered command with its current rows, oldest first.
    pub fn list(&self, term: &Terminal) -> Vec<CommandInfo> {
        let row = |pin: Option<PinId>| {
            pin.and_then(|pin| term.pin_point(pin))
                .map(|point| u64::from(point.y))
        };
        self.commands
            .iter()
            .map(|command| CommandInfo {
                mark: command.mark.clone(),
                rows: CommandRows {
                    prompt: row(command.prompt),
                    output: row(command.output),
                    end: row(command.end),
                },
            })
            .collect()
    }

    pub fn mark(&self, id: u64) -> Option<&CommandMark> {
        self.commands
            .iter()
            .map(|command| &command.mark)
            .find(|mark| mark.command_id == id)
    }

    /// The most recent finished commands, newest first.
    pub fn finished(&self) -> impl Iterator<Item = &CommandMark> {
        self.commands
            .iter()
            .rev()
            .filter(|command| command.mark.finished.is_some())
            .map(|command| &command.mark)
    }

    /// A command's output region, and whether its start already left scrollback.
    pub fn output_range(&self, term: &Terminal, id: u64) -> Option<(Option<TextRegion>, bool)> {
        let command = self
            .commands
            .iter()
            .find(|command| command.mark.command_id == id)?;
        let start = command.output.and_then(|pin| term.pin_point(pin));
        let truncated = start.is_none();
        let start = start.unwrap_or(Point { y: 0, x: 0 });
        let end = match command.end {
            Some(pin) => term.pin_point(pin).and_then(|point| before(term, point)),
            None => before(term, term.cursor_point()),
        };
        let region = end
            .filter(|&end| end >= start)
            .map(|end| TextRegion::Range { start, end });
        Some((region, truncated))
    }
}

/// The cell before `point` in reading order.
fn before(term: &Terminal, point: Point) -> Option<Point> {
    match (point.x, point.y) {
        (0, 0) => None,
        (0, y) => Some(Point {
            y: y - 1,
            x: term.cols() - 1,
        }),
        (x, y) => Some(Point { y, x: x - 1 }),
    }
}

fn replace(term: &mut Terminal, slot: &mut Option<PinId>, new: Option<PinId>) {
    if let Some(old) = std::mem::replace(slot, new) {
        term.unpin(old);
    }
}

fn release(term: &mut Terminal, pin: Option<PinId>) {
    if let Some(pin) = pin {
        term.unpin(pin);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(log: &mut CommandLog, term: &mut Terminal, bytes: &[u8]) -> Vec<CommandUpdate> {
        term.write(bytes);
        let events = term.take_semantic_prompts();
        log.apply(term, PaneId(1), Seq(0), events)
    }

    #[test]
    fn a_command_is_marked_with_its_text_output_and_exit() {
        let mut term = Terminal::new(40, 10).unwrap();
        term.record_semantic_prompts().unwrap();
        let mut log = CommandLog::default();
        assert!(feed(&mut log, &mut term, b"\x1b]133;D;0\x07").is_empty());
        let updates = feed(
            &mut log,
            &mut term,
            b"\x1b]7;file://h/tmp\x07\x1b]133;A\x07~ $ \x1b]133;B\x07ls -l\r\n\x1b]133;C\x07",
        );
        let Some(CommandUpdate::Mark(start)) = updates.last() else {
            panic!("{updates:?}")
        };
        assert_eq!(start.command.as_deref(), Some("ls -l"));
        assert_eq!(start.cwd.as_deref(), Some("/tmp"));
        assert_eq!(updates[0], CommandUpdate::AtPrompt(true));
        let updates = feed(&mut log, &mut term, b"a.txt\r\nb.txt\r\n\x1b]133;D;1\x07");
        let CommandUpdate::Mark(end) = &updates[0] else {
            panic!("{updates:?}")
        };
        assert_eq!(end.finished.unwrap().exit, Some(1));
        let (region, truncated) = log.output_range(&term, 1).unwrap();
        assert!(!truncated);
        let output = term.text_wrapped(region.unwrap(), Wrap::Join).unwrap();
        assert_eq!(output.trim_end(), "a.txt\nb.txt");
        let list = log.list(&term);
        assert_eq!(list[0].rows.prompt, Some(0));
        assert_eq!(list[0].rows.output, Some(1));
        assert_eq!(list[0].rows.end, Some(3));
    }

    /// Any program can report a command line and directory: what reaches clients, history and
    /// agents prints as it is.
    #[test]
    fn forged_command_lines_and_directories_print_as_they_are() {
        let mut term = Terminal::new(40, 10).unwrap();
        term.record_semantic_prompts().unwrap();
        let mut log = CommandLog::default();
        let updates = feed(
            &mut log,
            &mut term,
            "\x1b]7;file://h/tmp/a%0Ab\x07\x1b]133;A\x07$ \x1b]133;B\x07\
             \x1b]133;C;cmdline=make\u{202e}fr- mr\u{202c}\u{e0041} test\x07"
                .as_bytes(),
        );
        let Some(CommandUpdate::Mark(start)) = updates.last() else {
            panic!("{updates:?}")
        };
        assert_eq!(start.command.as_deref(), Some("makefr- mr test"));
        assert_eq!(start.cwd, None);
    }

    fn command(bytes: &[u8], cols: u16) -> Option<String> {
        let mut term = Terminal::new(cols, 10).unwrap();
        term.record_semantic_prompts().unwrap();
        let mut log = CommandLog::default();
        feed(&mut log, &mut term, bytes);
        log.list(&term)
            .last()
            .and_then(|info| info.mark.command.clone())
    }

    #[test]
    fn unmarked_hard_newlines_are_not_command_input() {
        assert_eq!(
            command(
                b"\x1b]133;A\x07$ \x1b]133;B\x07echo safe\r\ncompletion noise\r\n\x1b]133;C\x07",
                40
            )
            .as_deref(),
            Some("echo safe")
        );
    }

    #[test]
    fn marked_continuations_are_kept_without_their_prompt_text() {
        assert_eq!(command(b"\x1b]133;A\x07$ \x1b]133;B\x07echo first \\\r\n\x1b]133;P;k=s\x07> \x1b]133;B\x07second\r\nnoise\r\n\x1b]133;C\x07", 40).as_deref(), Some("echo first \\\nsecond"));
    }

    #[test]
    fn soft_wrapped_commands_keep_spaces_at_wrap_boundaries() {
        assert_eq!(
            command(
                b"\x1b]133;A\x07$ \x1b]133;B\x07printf 'a   b'\r\n\x1b]133;C\x07",
                10
            )
            .as_deref(),
            Some("printf 'a   b'")
        );
    }

    #[test]
    fn abandoned_input_is_dropped_even_without_an_output_start() {
        assert_eq!(
            command(
                b"\x1b]133;A\x07$ \x1b]133;B\x07abandoned\r\n\x1b]133;D\x07\x1b]133;C\x07",
                40
            ),
            None
        );
    }

    #[test]
    fn abandoned_inferred_input_is_also_released() {
        let mut term = Terminal::new(40, 10).unwrap();
        term.record_semantic_prompts().unwrap();
        let mut log = CommandLog::default();
        feed(&mut log, &mut term, b"\x1b]133;A\x07$ ");
        feed(&mut log, &mut term, b"abandoned\r\n\x1b]133;D\x07");
        feed(&mut log, &mut term, b"\x1b]133;C\x07");
        assert_eq!(log.list(&term).last().unwrap().mark.command, None);
    }

    #[test]
    fn multiline_primary_prompt_still_establishes_its_first_input_start() {
        assert_eq!(command(b"\x1b]133;A\x07directory\r\n\x1b]133;P;k=s\x07$ \x1b]133;B\x07echo safe\r\n\x1b]133;C\x07", 40).as_deref(), Some("echo safe"));
    }

    #[test]
    fn continuation_pins_are_bounded_and_overflow_does_not_guess_a_command() {
        let mut term = Terminal::new(40, 10).unwrap();
        term.record_semantic_prompts().unwrap();
        let mut log = CommandLog::default();
        feed(
            &mut log,
            &mut term,
            b"\x1b]133;A\x07$ \x1b]133;B\x07echo first\r\n",
        );
        for _ in 0..=MAX_CONTINUATIONS {
            feed(
                &mut log,
                &mut term,
                b"\x1b]133;P;k=s\x07> \x1b]133;B\x07next\r\n",
            );
        }
        assert_eq!(log.continuations.len(), MAX_CONTINUATIONS);
        feed(&mut log, &mut term, b"\x1b]133;C\x07");
        assert_eq!(log.list(&term).last().unwrap().mark.command, None);
        assert!(log.continuations.is_empty());
    }

    #[test]
    fn primary_prompt_redraw_replaces_the_old_input_start() {
        assert_eq!(command(b"\x1b]133;A\x07$ \x1b]133;B\x07old\r\nnoise\r\n\x1b]133;P;k=i\x07$ \x1b]133;B\x07new\r\n\x1b]133;C\x07", 40).as_deref(), Some("new"));
    }
}
