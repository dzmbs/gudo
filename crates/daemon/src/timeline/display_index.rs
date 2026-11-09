use std::collections::VecDeque;

use super::claude_record::{BlockKind, Record};

const PROMPTS_LIMIT: usize = 8;
const GROUPS_LIMIT: usize = 64;
const ITEMS_LIMIT: usize = 256;
const ID_LIMIT: usize = 128;

#[derive(Default)]
pub(super) struct DisplayIndex {
    current: Option<String>,
    prompts: VecDeque<DisplayPrompt>,
}

pub(super) struct DisplayPrompt {
    pub id: String,
    pub turn: String,
    pub groups: Vec<DisplayGroup>,
    pub is_usable: bool,
    item_count: usize,
}

pub(super) struct DisplayGroup {
    api_id: String,
    request_ref: Option<String>,
    pub items: Vec<String>,
}

impl DisplayIndex {
    pub fn prompt(&self, id: &str) -> Option<&DisplayPrompt> {
        self.prompts.iter().find(|prompt| prompt.id == id)
    }

    pub fn begin(&mut self, record: &Record, turn: &str) {
        self.current = None;
        let Some(id) = record
            .prompt_id
            .as_ref()
            .filter(|id| crate::claude_session::is_session_id(id))
        else {
            return;
        };
        if turn.len() > ID_LIMIT {
            return;
        }
        if let Some(prompt) = self.prompts.iter_mut().find(|prompt| &prompt.id == id) {
            if prompt.turn != turn {
                prompt.is_usable = false;
            }
        } else {
            self.prompts.push_back(DisplayPrompt {
                id: id.clone(),
                turn: turn.to_owned(),
                groups: Vec::new(),
                is_usable: true,
                item_count: 0,
            });
            if self.prompts.len() > PROMPTS_LIMIT {
                self.prompts.pop_front();
            }
        }
        self.current = Some(id.clone());
    }

    pub fn assistant(&mut self, record: &Record, record_id: &str) {
        let Some(current) = &self.current else {
            return;
        };
        let Some(prompt) = self.prompts.iter_mut().find(|prompt| &prompt.id == current) else {
            return;
        };
        if !prompt.is_usable || record.parent_tool_use_id.is_some() {
            return;
        }
        if !record.message.content.blocks().iter().any(|block| {
            block.kind == BlockKind::Text
                && block.text.as_ref().is_some_and(|text| !text.is_empty())
        }) {
            return;
        }
        let text_indices = record
            .message
            .content
            .blocks()
            .iter()
            .enumerate()
            .filter_map(|(index, block)| (block.kind == BlockKind::Text).then_some(index));
        let Some(api_id) = record
            .message
            .id
            .as_ref()
            .filter(|id| !id.is_empty() && id.len() <= ID_LIMIT)
        else {
            prompt.is_usable = false;
            return;
        };
        if record
            .request_ref
            .as_ref()
            .is_some_and(|id| id.len() > ID_LIMIT)
            || record_id.len().saturating_add(20) > ID_LIMIT
        {
            prompt.is_usable = false;
            return;
        }
        let group = prompt
            .groups
            .iter()
            .position(|group| &group.api_id == api_id && group.request_ref == record.request_ref);
        let group = match group {
            Some(index) => index,
            None if prompt.groups.len() < GROUPS_LIMIT => {
                prompt.groups.push(DisplayGroup {
                    api_id: api_id.clone(),
                    request_ref: record.request_ref.clone(),
                    items: Vec::new(),
                });
                prompt.groups.len() - 1
            }
            None => {
                prompt.is_usable = false;
                return;
            }
        };
        for index in text_indices {
            let id = format!("{record_id}:{index}");
            if prompt.groups[group].items.contains(&id) {
                continue;
            }
            if prompt.item_count >= ITEMS_LIMIT {
                prompt.is_usable = false;
                return;
            }
            prompt.groups[group].items.push(id);
            prompt.item_count += 1;
        }
    }
}
