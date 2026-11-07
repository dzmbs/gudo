use proto::{
    FileDiff, TimelineBody, TimelineItem, TimelineOp, TimelineSession, TimelineSnapshot,
    TimelineTool, TimelineUpdate,
};

#[cfg(test)]
#[path = "value_weight_tests.rs"]
mod tests;

const OUTPUT_HANDLE_FORMAT_BYTES: usize = 64;

/// Conservative postcard bound, cached when a value changes rather than serializing to measure.
/// String bytes are literal in postcard; doubled native metadata covers tags, lengths and varints.
/// This is a wire allowance, not a resident-memory measurement.
pub(super) fn item(item: &TimelineItem) -> usize {
    let fields = item.id.len() + optional(&item.turn) + optional(&item.parent);
    let body = match &item.body {
        TimelineBody::User {
            text, attachments, ..
        } => {
            text.len()
                + array(attachments)
                + attachments
                    .iter()
                    .map(|attachment| attachment.path.len() + optional(&attachment.media_type))
                    .sum::<usize>()
        }
        TimelineBody::Assistant { text, .. } | TimelineBody::Notice { text, .. } => text.len(),
        TimelineBody::Thinking { text, .. } => optional(text),
        TimelineBody::Plan { entries } => {
            array(entries) + entries.iter().map(|entry| entry.text.len()).sum::<usize>()
        }
        TimelineBody::Tool(tool) => tool_bytes(tool),
        TimelineBody::TurnEnd { .. } | TimelineBody::Unsupported => 0,
    };
    2 * std::mem::size_of_val(item) + fields + body
}

/// Bounds one queued update without creating a temporary encoded payload.
pub(super) fn update(value: &TimelineUpdate) -> usize {
    2 * std::mem::size_of_val(value) + operations(&value.operations)
}

/// Bounds a freshly produced operation batch before it enters the shared broadcast queue.
pub(super) fn operations(values: &[TimelineOp]) -> usize {
    2 * std::mem::size_of::<Vec<TimelineOp>>() + values.iter().map(operation).sum::<usize>()
}

fn operation(value: &TimelineOp) -> usize {
    let fields = match value {
        TimelineOp::Snapshot(value) => snapshot(value),
        TimelineOp::Upsert { item: value, .. } => item(value),
        TimelineOp::Append { id, text, .. } => id.len() + text.len(),
        TimelineOp::Remove { id, .. } => id.len(),
        TimelineOp::Session { session: value, .. } => session(value),
        TimelineOp::Unavailable { message } => message.len(),
        TimelineOp::Checkpoint { .. } => 0,
    };
    2 * std::mem::size_of_val(value) + fields
}

fn snapshot(value: &TimelineSnapshot) -> usize {
    2 * std::mem::size_of_val(value)
        + session_fields(&value.session)
        + value.items.iter().map(item).sum::<usize>()
}

fn session(value: &TimelineSession) -> usize {
    2 * std::mem::size_of_val(value) + session_fields(value)
}

fn session_fields(value: &TimelineSession) -> usize {
    value.native_session.len()
        + optional(&value.title)
        + optional(&value.model)
        + array(&value.commands)
        + value
            .commands
            .iter()
            .map(|command| command.name.len() + command.description.len())
            .sum::<usize>()
}

fn optional(text: &Option<String>) -> usize {
    text.as_ref().map_or(0, String::len)
}

fn array<T>(values: &[T]) -> usize {
    2 * std::mem::size_of_val(values)
}

fn tool_bytes(tool: &TimelineTool) -> usize {
    let output = tool.output.as_ref().map_or(0, |output| {
        // OutputHandle's string form adds two decimal u64s and separators to the native id.
        output.handle.id().len() + output.preview.len() + OUTPUT_HANDLE_FORMAT_BYTES
    });
    tool.name.len()
        + tool.title.len()
        + tool.input.len()
        + output
        + array(&tool.diff)
        + tool.diff.iter().map(diff_bytes).sum::<usize>()
}

fn diff_bytes(diff: &FileDiff) -> usize {
    diff.path.len()
        + optional(&diff.old_path)
        + array(&diff.hunks)
        + diff
            .hunks
            .iter()
            .map(|hunk| {
                hunk.header.len()
                    + array(&hunk.lines)
                    + hunk.lines.iter().map(|line| line.text.len()).sum::<usize>()
            })
            .sum::<usize>()
}
