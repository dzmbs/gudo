use proto::{FileDiff, TimelineBody, TimelineItem, TimelineTool};

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
