use super::*;
use serde_json::json;

const FIXTURE: &str = include_str!("../../tests/fixtures/timeline/claude-2.1.318.jsonl");

fn parser() -> ClaudeTimeline {
    ClaudeTimeline::new("test-session".into())
}

fn parse(parser: &mut ClaudeTimeline, record: Value) -> Vec<TimelineItem> {
    parser
        .parse_line(&serde_json::to_vec(&record).unwrap(), 42)
        .unwrap()
}

#[test]
fn invalid_tool_identifiers_do_not_advertise_unreadable_output() {
    let mut parser = parser();
    for id in [String::new(), "x".repeat(257)] {
        let items = parse(
            &mut parser,
            json!({"type":"user", "message":{"content":[{
                "type":"tool_result", "tool_use_id": id, "content":"done"
            }]}}),
        );
        let TimelineBody::Tool(tool) = &items[0].body else {
            panic!("tool result")
        };
        assert!(tool.output.is_none());
    }
}

#[test]
fn current_cli_fixture_merges_tool_results_without_duplicate_calls() {
    let first: Value = serde_json::from_str(FIXTURE.lines().next().unwrap()).unwrap();
    let mut parser = ClaudeTimeline::new(first["sessionId"].as_str().unwrap().into());
    let mut items = HashMap::new();
    let mut offset = 0;
    for line in FIXTURE.lines() {
        for item in parser.parse_line(line.as_bytes(), offset).unwrap() {
            items.insert(item.id.clone(), item);
        }
        offset += line.len() as u64 + 1;
    }
    assert_eq!(items.len(), 8);
    assert_eq!(parser.session.model.as_deref(), Some("claude-sonnet-4-6"));
    assert_eq!(
        parser.session.permission_mode.as_deref(),
        Some("bypassPermissions")
    );
    let TimelineBody::Tool(shell) = &items["toolu_fixture_bash"].body else {
        panic!()
    };
    assert_eq!(shell.status, TimelineToolStatus::Done);
    assert_eq!(shell.kind, TimelineToolKind::Shell);
    assert_eq!(shell.title, "Check the fixture");
    assert_eq!(shell.output.as_ref().unwrap().preview, "fixture output");
    assert_eq!(items["toolu_fixture_bash"].revision, 2);
    let TimelineBody::Tool(edit) = &items["toolu_fixture_edit"].body else {
        panic!()
    };
    assert_eq!((edit.diff[0].additions, edit.diff[0].deletions), (1, 1));
    assert_eq!(edit.diff[0].hunks[0].lines[0].text, "first line");
    assert_eq!(edit.diff[0].hunks[0].lines[1].kind, LineKind::Added);
    let TimelineBody::Tool(write) = &items["toolu_fixture_write"].body else {
        panic!()
    };
    assert_eq!(write.diff[0].change, FileChange::Added);
    assert_eq!(write.diff[0].additions, 1);
    let TimelineBody::Tool(read) = &items["toolu_fixture_read"].body else {
        panic!()
    };
    assert_eq!(read.output.as_ref().unwrap().preview, "changed line\n");
    assert_eq!(
        items
            .values()
            .filter(|item| matches!(item.body, TimelineBody::Thinking { .. }))
            .count(),
        1
    );
    assert_eq!(
        items
            .values()
            .filter(|item| matches!(item.body, TimelineBody::Assistant { .. }))
            .count(),
        2
    );
    assert!(items.values().all(|item| item.parent.is_none()));
}

#[test]
fn plain_users_and_attachment_users_keep_their_turn_identity() {
    let mut parser = parser();
    let items = parse(
        &mut parser,
        json!({"type":"user","uuid":"user-1","timestamp":"2026-01-01T00:00:00Z","message":{"content":[{"type":"text","text":"Check this"},{"type":"image","source":{"path":"/fixture/photo.jpg","media_type":"image/jpeg"}}]}}),
    );
    let item = &items[0];
    assert_eq!(item.turn.as_deref(), Some("user-1"));
    assert_eq!(item.at, UnixMillis(1767225600000));
    assert_eq!(item.origin, TimelineOrigin::Terminal);
    let TimelineBody::User {
        text,
        attachments,
        queued,
    } = &item.body
    else {
        panic!()
    };
    assert_eq!(text, "Check this");
    assert!(!queued);
    assert_eq!(attachments[0].path, "/fixture/photo.jpg");
    let items = parse(
        &mut parser,
        json!({"type":"assistant","uuid":"assistant-1","message":{"content":[{"type":"text","text":"Done"},{"type":"text","text":"Next"}]}}),
    );
    assert_eq!(items[0].id, "assistant-1:0");
    assert_eq!(items[1].id, "assistant-1:1");
    assert_eq!(items[1].turn.as_deref(), Some("user-1"));
}

#[test]
fn titles_and_permission_modes_update_session_metadata() {
    let mut parser = parser();
    assert!(
        parse(
            &mut parser,
            json!({"type":"ai-title","aiTitle":"Check the build"})
        )
        .is_empty()
    );
    assert_eq!(parser.session.title.as_deref(), Some("Check the build"));
    parse(
        &mut parser,
        json!({"type":"custom-title","customTitle":"Build"}),
    );
    assert_eq!(parser.session.title.as_deref(), Some("Build"));
    assert!(parse(&mut parser, json!({"type":"permission-mode","mode":"plan"})).is_empty());
    assert_eq!(parser.session.permission_mode.as_deref(), Some("plan"));
}

#[test]
fn thinking_never_exposes_a_signature_or_redacted_data() {
    let items = parse(
        &mut parser(),
        json!({"type":"assistant","uuid":"a","message":{"content":[{"type":"thinking","thinking":"Checking the build","signature":"private-signature"},{"type":"redacted_thinking","data":"private-data"}]}}),
    );
    assert!(
        matches!(&items[0].body, TimelineBody::Thinking { text: Some(text), .. } if text == "Checking the build")
    );
    assert!(matches!(
        items[1].body,
        TimelineBody::Thinking { text: None, .. }
    ));
    let encoded = serde_json::to_string(&items).unwrap();
    assert!(!encoded.contains("private-"));
}

#[test]
fn todo_updates_use_one_plan_id_per_turn() {
    let mut parser = parser();
    parse(
        &mut parser,
        json!({"type":"user","uuid":"turn-1","message":{"content":"Fix the build"}}),
    );
    let first = parse(
        &mut parser,
        json!({"type":"assistant","uuid":"a","message":{"content":[{"type":"tool_use","id":"todo-1","name":"TodoWrite","input":{"todos":[{"content":"Build","status":"in_progress"}]}}]}}),
    );
    let second = parse(
        &mut parser,
        json!({"type":"assistant","uuid":"b","message":{"content":[{"type":"tool_use","id":"todo-2","name":"TodoWrite","input":{"todos":[{"content":"Build","status":"completed"}]}}]}}),
    );
    assert_eq!(first[0].id, second[0].id);
    let TimelineBody::Plan { entries } = &second[0].body else {
        panic!()
    };
    assert_eq!(entries[0].status, TimelinePlanStatus::Completed);
}

#[test]
fn task_results_keep_the_subagent_description_and_duration() {
    let mut parser = parser();
    parse(
        &mut parser,
        json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"task-1","name":"Task","input":{"description":"Check the tests","prompt":"Inspect the tests"}}]}}),
    );
    let items = parse(
        &mut parser,
        json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"task-1","content":[{"type":"text","text":"Tests passed"}]}]},"toolUseResult":{"agentId":"worker-1","totalDurationMs":1200,"totalTokens":128}}),
    );
    let TimelineBody::Tool(tool) = &items[0].body else {
        panic!()
    };
    assert_eq!(tool.title, "Check the tests");
    assert_eq!(tool.kind, TimelineToolKind::Task);
    assert_eq!(tool.duration_ms, Some(1200));
    assert_eq!(tool.output.as_ref().unwrap().preview, "Tests passed");
}

#[test]
fn failed_denied_and_interrupted_results_are_distinct() {
    for (result, permission, expected) in [
        (json!({}), "accept", TimelineToolStatus::Failed),
        (json!({}), "deny", TimelineToolStatus::Denied),
        (
            json!({"interrupted":true}),
            "accept",
            TimelineToolStatus::Interrupted,
        ),
    ] {
        let items = parse(
            &mut parser(),
            json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":"Stopped","is_error":true}]},"toolUseResult":result,"permissionDecision":{"decision":permission}}),
        );
        let TimelineBody::Tool(tool) = &items[0].body else {
            panic!()
        };
        assert_eq!(tool.status, expected);
    }
}

#[test]
fn turn_duration_does_not_count_each_content_block_as_an_api_call() {
    let mut parser = parser();
    let assistant = json!({"type":"assistant","message":{"id":"same-message","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":4},"content":[{"type":"text","text":"First"}]}});
    parse(&mut parser, assistant.clone());
    parse(&mut parser, assistant);
    let items = parse(
        &mut parser,
        json!({"type":"system","subtype":"turn_duration","durationMs":1234}),
    );
    assert_eq!(
        items[0].body,
        TimelineBody::TurnEnd {
            duration_ms: 1234,
            input_tokens: Some(60),
            output_tokens: Some(4)
        }
    );
}

#[test]
fn compaction_and_service_errors_are_not_user_prompts() {
    for (record, expected) in [
        (
            json!({"type":"system","subtype":"compact_boundary"}),
            TimelineNoticeKind::Compacted,
        ),
        (
            json!({"type":"user","isCompactSummary":true,"message":{"content":"Summary"}}),
            TimelineNoticeKind::Compacted,
        ),
        (
            json!({"type":"system","subtype":"api_error"}),
            TimelineNoticeKind::Error,
        ),
        (
            json!({"type":"system","subtype":"local_command","content":"/clear"}),
            TimelineNoticeKind::Cleared,
        ),
    ] {
        let items = parse(&mut parser(), record);
        assert!(matches!(items[0].body, TimelineBody::Notice { kind, .. } if kind == expected));
    }
}

#[test]
fn unknown_records_and_blocks_are_skipped_but_malformed_json_is_reported() {
    let mut parser = parser();
    for record in [
        json!({"type":"future-entry"}),
        json!({"type":"assistant","message":{"content":[{"type":"future-block"}]}}),
        json!({"type":"user","isMeta":true,"message":{"content":"System reminder"}}),
        json!({"type":"assistant","isSidechain":true}),
        json!({"type":"user","sessionId":"another-session","message":{"content":"Not this session"}}),
    ] {
        assert!(parse(&mut parser, record).is_empty());
    }
    assert!(parser.parse_line(b"{broken", 0).is_err());
}

#[test]
fn outputs_inputs_and_diff_previews_are_bounded() {
    let mut parser = parser();
    parse(
        &mut parser,
        json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"edit","name":"Edit","input":{"old_string":"a".repeat(INPUT_LIMIT+1)}}]}}),
    );
    let lines: Vec<_> = (0..100).map(|index| format!("+line {index}")).collect();
    let items = parse(
        &mut parser,
        json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"edit","content":"🦀".repeat(5000)}]},"toolUseResult":{"filePath":"/fixture/file","structuredPatch":[{"newStart":1,"newLines":100,"lines":lines}]}}),
    );
    let TimelineBody::Tool(tool) = &items[0].body else {
        panic!()
    };
    assert!(tool.input.len() <= INPUT_LIMIT);
    assert!(serde_json::from_str::<Value>(&tool.input).is_ok());
    assert_eq!(tool.output.as_ref().unwrap().preview.len(), 4096);
    assert_eq!(tool.output.as_ref().unwrap().bytes, 20000);
    assert_eq!(tool.diff[0].hunks[0].lines.len(), 6);
    assert_eq!(tool.diff[0].additions, 100);
    assert!(tool.diff[0].hunks_omitted);
    let oversized = json!({"type":"user","message":{"content":"a".repeat(TEXT_LIMIT+1)}});
    assert!(matches!(
        parser.parse_line(&serde_json::to_vec(&oversized).unwrap(), 0),
        Err(ParseError::MessageTooLarge)
    ));
}

#[test]
fn completed_tool_cache_stays_bounded() {
    let mut parser = parser();
    for index in 0..1000 {
        parse(
            &mut parser,
            json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":format!("tool-{index}"),"name":"Read","input":{}}]}}),
        );
    }
    assert_eq!(parser.tools.len(), TOOL_CACHE_LIMIT);
    assert_eq!(parser.tool_order.len(), TOOL_CACHE_LIMIT);
}
