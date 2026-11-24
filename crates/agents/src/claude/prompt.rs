//! Claude Code's questions (`AskUserQuestion`) and plan approvals (`ExitPlanMode`), held in a
//! `PreToolUse` hook and answered from Chat.

use serde_json::{Value, json};

use super::ClaudeCode;

/// The tool Claude Code asks the user questions with.
pub const QUESTION_TOOL: &str = "AskUserQuestion";

/// The tool Claude Code asks to leave plan mode with, carrying the plan.
pub const PLAN_TOOL: &str = "ExitPlanMode";

/// The event name the hook settings give the held `PreToolUse` hook, so the shim and the
/// daemon tell it from the short `PreToolUse` hook of sessions started with older settings.
pub const HELD_TOOL_EVENT: &str = "HeldPreToolUse";

const MAX_QUESTIONS: usize = 8;
const MAX_OPTIONS: usize = 16;
const MAX_TEXT: usize = 4 * 1024;
const MAX_PLAN: usize = 256 * 1024;

/// What the user said about a plan.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanAnswer {
    Approve,
    /// Keep planning, with what to change (may be empty).
    KeepPlanning(String),
}

fn bounded(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}

fn text_at<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn pre_tool_output(decision: Value) -> Value {
    let mut output = json!({ "hookEventName": "PreToolUse" });
    if let (Some(output), Some(decision)) = (output.as_object_mut(), decision.as_object()) {
        output.extend(decision.clone());
    }
    json!({ "hookSpecificOutput": output })
}

impl ClaudeCode {
    /// Whether a held `PreToolUse` hook for `tool` waits for Chat.
    pub fn holds_tool(tool: &str) -> bool {
        matches!(tool, QUESTION_TOOL | PLAN_TOOL)
    }

    /// The questions in an `AskUserQuestion` input, bounded.
    pub fn questions(tool_input: &Value) -> Vec<proto::AgentQuestion> {
        let Some(questions) = tool_input.get("questions").and_then(Value::as_array) else {
            return Vec::new();
        };
        questions
            .iter()
            .take(MAX_QUESTIONS)
            .filter_map(|question| {
                let text = text_at(question, "question");
                (!text.is_empty()).then(|| proto::AgentQuestion {
                    header: bounded(text_at(question, "header"), MAX_TEXT),
                    question: bounded(text, MAX_TEXT),
                    options: question
                        .get("options")
                        .and_then(Value::as_array)
                        .map(|options| {
                            options
                                .iter()
                                .take(MAX_OPTIONS)
                                .map(|option| proto::AgentQuestionOption {
                                    label: bounded(text_at(option, "label"), MAX_TEXT),
                                    description: bounded(text_at(option, "description"), MAX_TEXT),
                                })
                                .filter(|option| !option.label.is_empty())
                                .collect()
                        })
                        .unwrap_or_default(),
                    multi_select: question
                        .get("multiSelect")
                        .and_then(Value::as_bool)
                        .unwrap_or_default(),
                })
            })
            .collect()
    }

    /// The plan in an `ExitPlanMode` input, bounded.
    pub fn plan(tool_input: &Value) -> Option<String> {
        tool_input
            .get("plan")
            .and_then(Value::as_str)
            .filter(|plan| !plan.trim().is_empty())
            .map(|plan| bounded(plan, MAX_PLAN))
    }

    /// The held `PreToolUse` hook's answer to questions: allowed, with the original input and
    /// `answers` keyed by each question's full text, which is what the tool returns to the
    /// model and what the terminal then shows as answered.
    pub fn question_response(tool_input: &Value, answers: &[proto::QuestionAnswer]) -> Value {
        let mut updated = tool_input.clone();
        let answered: serde_json::Map<String, Value> = answers
            .iter()
            .map(|answer| (answer.question.clone(), answer.answer.clone().into()))
            .collect();
        if let Some(fields) = updated.as_object_mut() {
            fields.insert("answers".into(), Value::Object(answered));
        }
        pre_tool_output(json!({
            "permissionDecision": "allow",
            "updatedInput": updated,
        }))
    }

    /// The held `PreToolUse` hook's answer to a plan.
    pub fn plan_response(tool_input: &Value, answer: &PlanAnswer) -> Value {
        match answer {
            PlanAnswer::Approve => pre_tool_output(json!({
                "permissionDecision": "allow",
                "updatedInput": tool_input,
            })),
            PlanAnswer::KeepPlanning(feedback) if feedback.trim().is_empty() => {
                Self::refusal_response("The user wants to keep planning.")
            }
            PlanAnswer::KeepPlanning(feedback) => Self::refusal_response(&format!(
                "The user wants to keep planning: {}",
                feedback.trim()
            )),
        }
    }

    /// The held `PreToolUse` hook's refusal, with `reason` for the model.
    pub fn refusal_response(reason: &str) -> Value {
        pre_tool_output(json!({
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input() -> Value {
        json!({"questions":[
            {"question":"Which framework?","header":"Framework","multiSelect":false,
             "options":[{"label":"React","description":"Components"},{"label":"Vue","description":""}]},
            {"question":"Which tests?","header":"Tests","multiSelect":true,"options":[]}
        ]})
    }

    #[test]
    fn questions_are_read_with_their_options() {
        let questions = ClaudeCode::questions(&input());
        assert_eq!(questions.len(), 2);
        assert_eq!(questions[0].header, "Framework");
        assert_eq!(questions[0].options[0].label, "React");
        assert_eq!(questions[0].options[0].description, "Components");
        assert!(!questions[0].multi_select);
        assert!(questions[1].multi_select);
    }

    #[test]
    fn answers_go_into_the_input_keyed_by_question() {
        let response = ClaudeCode::question_response(
            &input(),
            &[proto::QuestionAnswer {
                question: "Which framework?".into(),
                answer: "React".into(),
            }],
        );
        let output = &response["hookSpecificOutput"];
        assert_eq!(output["hookEventName"], "PreToolUse");
        assert_eq!(output["permissionDecision"], "allow");
        assert_eq!(
            output["updatedInput"]["answers"]["Which framework?"],
            "React"
        );
        assert_eq!(output["updatedInput"]["questions"], input()["questions"]);
    }

    #[test]
    fn a_plan_is_approved_or_sent_back_with_feedback() {
        let plan = json!({"plan":"# Plan"});
        assert_eq!(ClaudeCode::plan(&plan).as_deref(), Some("# Plan"));
        let approved = ClaudeCode::plan_response(&plan, &PlanAnswer::Approve);
        assert_eq!(
            approved["hookSpecificOutput"]["permissionDecision"],
            "allow"
        );
        let kept = ClaudeCode::plan_response(&plan, &PlanAnswer::KeepPlanning("add tests".into()));
        assert_eq!(kept["hookSpecificOutput"]["permissionDecision"], "deny");
        assert_eq!(
            kept["hookSpecificOutput"]["permissionDecisionReason"],
            "The user wants to keep planning: add tests"
        );
    }
}
