use super::{
    TimelineBody, TimelineField, TimelineItem, TimelineNoticeKind, TimelineOp, TimelineOrigin,
    TimelinePlanStatus, TimelineSnapshot, TimelineToolKind, TimelineToolStatus, TimelineVersion,
};

const UNSUPPORTED_ITEM: &str = "This Chat item is not supported. Open Terminal.";

impl TimelineVersion {
    pub fn item(self, item: &mut TimelineItem) {
        match self {
            Self::V1 => v1_item(item),
        }
    }

    pub fn snapshot(self, mut snapshot: TimelineSnapshot) -> TimelineSnapshot {
        for item in &mut snapshot.items {
            self.item(item);
        }
        snapshot
    }

    pub fn operations(self, operations: Vec<TimelineOp>) -> Vec<TimelineOp> {
        operations
            .into_iter()
            .map(|operation| self.operation(operation))
            .collect()
    }

    fn operation(self, mut operation: TimelineOp) -> TimelineOp {
        if !self.supports_operation(&operation) {
            return unavailable();
        }
        match &mut operation {
            TimelineOp::Snapshot(snapshot) => {
                for item in &mut snapshot.items {
                    self.item(item);
                }
            }
            TimelineOp::Upsert { item, .. } => self.item(item),
            TimelineOp::Append { field, .. } if !self.supports_field(*field) => {
                return unavailable();
            }
            _ => {}
        }
        operation
    }

    fn supports_operation(self, operation: &TimelineOp) -> bool {
        // Closed whitelists keep appended variants out of older postcard decoders.
        match self {
            Self::V1 => matches!(
                operation,
                TimelineOp::Snapshot(_)
                    | TimelineOp::Upsert { .. }
                    | TimelineOp::Append { .. }
                    | TimelineOp::Remove { .. }
                    | TimelineOp::Session { .. }
                    | TimelineOp::Unavailable { .. }
                    | TimelineOp::Checkpoint { .. }
            ),
        }
    }

    fn supports_field(self, field: TimelineField) -> bool {
        match self {
            Self::V1 => matches!(
                field,
                TimelineField::Text | TimelineField::Output | TimelineField::Thinking
            ),
        }
    }
}

fn v1_item(item: &mut TimelineItem) {
    if !matches!(
        item.origin,
        TimelineOrigin::Terminal | TimelineOrigin::Agent | TimelineOrigin::App(_)
    ) {
        item.origin = TimelineOrigin::Agent;
        item.body = TimelineBody::Unsupported;
    }
    match &mut item.body {
        TimelineBody::User { .. }
        | TimelineBody::Assistant { .. }
        | TimelineBody::Thinking { .. }
        | TimelineBody::TurnEnd { .. } => {}
        TimelineBody::Plan { entries } => {
            for entry in entries {
                entry.status = v1_plan_status(entry.status);
            }
        }
        TimelineBody::Tool(tool) => {
            tool.kind = v1_tool_kind(tool.kind);
            tool.status = v1_tool_status(tool.status);
        }
        TimelineBody::Notice { kind, .. } => *kind = v1_notice_kind(*kind),
        _ => {
            item.body = TimelineBody::Notice {
                kind: TimelineNoticeKind::Error,
                text: UNSUPPORTED_ITEM.into(),
            }
        }
    }
}

fn v1_plan_status(status: TimelinePlanStatus) -> TimelinePlanStatus {
    if matches!(
        status,
        TimelinePlanStatus::Pending
            | TimelinePlanStatus::InProgress
            | TimelinePlanStatus::Completed
    ) {
        status
    } else {
        TimelinePlanStatus::Pending
    }
}

fn v1_tool_status(status: TimelineToolStatus) -> TimelineToolStatus {
    if matches!(
        status,
        TimelineToolStatus::Running
            | TimelineToolStatus::Done
            | TimelineToolStatus::Failed
            | TimelineToolStatus::Denied
            | TimelineToolStatus::Interrupted
    ) {
        status
    } else {
        TimelineToolStatus::Interrupted
    }
}

fn v1_tool_kind(kind: TimelineToolKind) -> TimelineToolKind {
    if matches!(
        kind,
        TimelineToolKind::Shell
            | TimelineToolKind::Read
            | TimelineToolKind::Search
            | TimelineToolKind::Edit
            | TimelineToolKind::Write
            | TimelineToolKind::Fetch
            | TimelineToolKind::WebSearch
            | TimelineToolKind::Mcp
            | TimelineToolKind::Task
            | TimelineToolKind::Other
    ) {
        kind
    } else {
        TimelineToolKind::Other
    }
}

fn v1_notice_kind(kind: TimelineNoticeKind) -> TimelineNoticeKind {
    if matches!(
        kind,
        TimelineNoticeKind::Compacted
            | TimelineNoticeKind::Cleared
            | TimelineNoticeKind::ModelChanged
            | TimelineNoticeKind::ModeChanged
            | TimelineNoticeKind::Error
            | TimelineNoticeKind::Retry
            | TimelineNoticeKind::Interrupted
    ) {
        kind
    } else {
        TimelineNoticeKind::Error
    }
}

fn unavailable() -> TimelineOp {
    TimelineOp::Unavailable {
        message: "This Chat update is not supported. Open Terminal.".into(),
    }
}
