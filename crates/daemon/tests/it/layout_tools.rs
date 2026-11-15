//! The layout tools agents arrange panes with: what each change did (`effects`), the user's
//! focus and every tab's focused pane left alone, refusals that say why, the pane caps, and
//! the tab-grouped pane listing.

use client_core::ClientConfig;
use client_core::proto::{LayoutOp, PaneId, Project, UnixMillis};
use daemon::{Daemon, TermErrorCode, TermReply, ToolError};
use serde_json::{Value, json};

use crate::support::{TestClient, start_with, ticket};
use crate::term::Caller;

struct Setup {
    _dir: tempfile::TempDir,
    _daemon: Daemon,
    user: TestClient,
    agent_pane: PaneId,
    agent: Caller,
}

async fn setup(edit: impl FnOnce(&mut daemon::Config)) -> Setup {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), edit).await;
    let mut user = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let agent_pane = user.attach_and_follow().await;
    let agent = Caller {
        socket: daemon.hook_socket().to_owned(),
        token: std::fs::read_to_string(dir.path().join("hook.token")).unwrap(),
        pane: agent_pane.0.to_string(),
    };
    Setup {
        _dir: dir,
        _daemon: daemon,
        user,
        agent_pane,
        agent,
    }
}

async fn refusal(caller: &Caller, tool: &str, args: Value) -> ToolError {
    match caller.call(tool, args.clone()).await {
        TermReply::Error(error) => error,
        TermReply::Ok(value) => panic!("{tool} {args} was allowed: {value}"),
    }
}

fn pane_id(value: &Value) -> String {
    value["pane"]["id"].as_str().unwrap().to_owned()
}

fn effect<'a>(result: &'a Value, pane: &str) -> &'a Value {
    result["effects"]
        .as_array()
        .unwrap_or_else(|| panic!("no effects: {result}"))
        .iter()
        .find(|effect| effect["pane"] == pane)
        .unwrap_or_else(|| panic!("no effect on {pane}: {result}"))
}

fn changes(effect: &Value) -> Vec<&str> {
    effect["changes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|change| change.as_str().unwrap())
        .collect()
}

fn tab_listing<'a>(list: &'a Value, tab: &str) -> &'a Value {
    list["tabs"]
        .as_array()
        .unwrap_or_else(|| panic!("no tabs: {list}"))
        .iter()
        .find(|listed| listed["id"] == tab)
        .unwrap_or_else(|| panic!("no tab {tab}: {list}"))
}

#[tokio::test(flavor = "multi_thread")]
async fn docking_beside_a_pane_in_another_tab_needs_move_tab() {
    let Setup {
        mut user,
        agent_pane,
        agent,
        _dir,
        _daemon,
        ..
    } = setup(|_| {}).await;
    let home_tab = format!("t{}", user.tab().tab_id.0);
    let other = agent.ok("tab_new", json!({})).await;
    let other_tab = other["tab"].as_str().unwrap().to_owned();
    let beside = pane_id(&other);
    let window = pane_id(&agent.ok("pane_split", json!({ "float": true })).await);

    let refused = refusal(
        &agent,
        "pane_dock",
        json!({ "pane": window, "beside": beside }),
    )
    .await;
    assert_eq!(refused.code, TermErrorCode::CrossTab, "{refused:?}");
    assert!(
        refused.message.contains(&home_tab) && refused.message.contains(&other_tab),
        "{refused:?}"
    );
    let list = agent.ok("pane_list", json!({})).await;
    assert!(
        tab_listing(&list, &home_tab)["floats"][0]["panes"]
            .as_array()
            .unwrap()
            .contains(&json!(window)),
        "the refused dock moved nothing: {list}"
    );

    let moved = agent
        .ok(
            "pane_dock",
            json!({ "pane": window, "beside": beside, "moveTab": true }),
        )
        .await;
    let window_effect = effect(&moved, &window);
    assert!(changes(window_effect).contains(&"tab"), "{moved}");
    assert_eq!(window_effect["was"]["tab"], home_tab, "{moved}");
    assert_eq!(window_effect["now"]["tab"], other_tab, "{moved}");
    assert_eq!(moved["moved"]["from"], home_tab, "{moved}");
    assert_eq!(moved["moved"]["to"], other_tab, "{moved}");

    let list = agent.ok("pane_list", json!({})).await;
    assert_eq!(tab_listing(&list, &other_tab)["focused"], beside, "{list}");
    user.until("the dock", |client| {
        client.layout.as_ref().is_some_and(|layout| {
            layout.tabs.iter().any(|tab| {
                crate::support::leaves(&tab.root)
                    .iter()
                    .any(|pane| format!("p{}", pane.0) == window)
                    && format!("t{}", tab.tab_id.0) == other_tab
            })
        })
    })
    .await;
    assert_eq!(user.focused(), agent_pane, "the user's tab stays in front");
}

#[tokio::test(flavor = "multi_thread")]
async fn layout_results_report_effects_and_leave_every_tabs_focus() {
    let Setup {
        mut user,
        agent_pane,
        agent,
        _dir,
        _daemon,
        ..
    } = setup(|_| {}).await;
    let me = format!("p{}", agent_pane.0);

    let split = agent.ok("pane_split", json!({})).await;
    let tiled = pane_id(&split);
    assert_eq!(changes(effect(&split, &tiled)), ["opened"], "{split}");
    assert!(effect(&split, &tiled)["was"].is_null(), "{split}");

    let floated = agent.ok("pane_float", json!({ "pane": tiled })).await;
    let float_effect = effect(&floated, &tiled);
    assert!(changes(float_effect).contains(&"float"), "{floated}");
    assert_eq!(float_effect["now"]["floating"], true, "{floated}");
    assert!(float_effect["now"]["frame"].is_object(), "{floated}");

    for (tool, args) in [
        ("pane_minimize", json!({ "pane": tiled })),
        ("pane_raise", json!({ "pane": tiled })),
        ("pane_dock", json!({ "pane": tiled })),
    ] {
        let result = agent.ok(tool, args).await;
        assert!(result["effects"].is_array(), "{tool}: {result}");
        assert!(
            result["effects"]
                .as_array()
                .unwrap()
                .iter()
                .all(|effect| effect["pane"] != me),
            "{tool} touched the agent's own pane: {result}"
        );
    }

    // A tab the user is not looking at keeps its focused pane through a float and a dock.
    let other = agent.ok("tab_new", json!({})).await;
    let other_tab = other["tab"].as_str().unwrap().to_owned();
    let other_pane = pane_id(&other);
    let window = pane_id(
        &agent
            .ok("pane_split", json!({ "of": other_pane, "float": true }))
            .await,
    );
    let docked = agent.ok("pane_dock", json!({ "pane": window })).await;
    assert!(
        !changes(effect(&docked, &window)).contains(&"focus"),
        "{docked}"
    );
    let list = agent.ok("pane_list", json!({})).await;
    assert_eq!(
        tab_listing(&list, &other_tab)["focused"],
        other_pane,
        "{list}"
    );
    let floated = agent.ok("pane_float", json!({ "pane": window })).await;
    assert!(
        !changes(effect(&floated, &window)).contains(&"focus"),
        "{floated}"
    );
    let list = agent.ok("pane_list", json!({})).await;
    assert_eq!(
        tab_listing(&list, &other_tab)["focused"],
        other_pane,
        "{list}"
    );

    let closed = agent.ok("pane_close", json!({ "pane": window })).await;
    assert_eq!(changes(effect(&closed, &window)), ["closed"], "{closed}");
    assert!(effect(&closed, &window)["now"].is_null(), "{closed}");

    user.until("the agent's tabs", |client| {
        client
            .layout
            .as_ref()
            .is_some_and(|layout| layout.tabs.len() == 2)
    })
    .await;
    assert_eq!(user.focused(), agent_pane);
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_the_last_docked_pane_keeps_floats_unless_asked() {
    let Setup {
        agent,
        _dir,
        _daemon,
        ..
    } = setup(|_| {}).await;
    let tab = agent.ok("tab_new", json!({})).await;
    let tab_id = tab["tab"].as_str().unwrap().to_owned();
    let docked = pane_id(&tab);
    let window = pane_id(
        &agent
            .ok("pane_split", json!({ "of": docked, "float": true }))
            .await,
    );

    let refused = refusal(&agent, "pane_close", json!({ "pane": docked })).await;
    assert_eq!(refused.code, TermErrorCode::InvalidArgs, "{refused:?}");
    assert!(
        refused.message.contains(&window) && refused.message.contains("closeFloats"),
        "{refused:?}"
    );
    let list = agent.ok("pane_list", json!({ "tab": tab_id })).await;
    assert!(
        tab_listing(&list, &tab_id)["floats"][0]["panes"]
            .as_array()
            .unwrap()
            .contains(&json!(window)),
        "the window stays floating: {list}"
    );

    let closed = agent
        .ok("pane_close", json!({ "pane": docked, "closeFloats": true }))
        .await;
    assert_eq!(changes(effect(&closed, &docked)), ["closed"], "{closed}");
    assert_eq!(changes(effect(&closed, &window)), ["closed"], "{closed}");
}

#[tokio::test(flavor = "multi_thread")]
async fn floating_again_restores_the_last_frame_and_pin() {
    let Setup {
        agent,
        _dir,
        _daemon,
        ..
    } = setup(|_| {}).await;
    let pane = pane_id(&agent.ok("pane_split", json!({})).await);
    let frame = json!({ "x": 0.3, "y": 0.2, "w": 0.5, "h": 0.6 });
    agent
        .ok(
            "pane_float",
            json!({ "pane": pane, "frame": frame, "pinned": true }),
        )
        .await;
    agent.ok("pane_dock", json!({ "pane": pane })).await;
    let again = agent.ok("pane_float", json!({ "pane": pane })).await;
    assert_eq!(again["pane"]["float"]["frame"], frame, "{again}");
    assert_eq!(again["pane"]["float"]["pinned"], true, "{again}");
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_a_pane_that_never_existed_is_not_found() {
    let Setup {
        agent,
        _dir,
        _daemon,
        ..
    } = setup(|_| {}).await;
    let refused = refusal(&agent, "pane_close", json!({ "pane": "p99999" })).await;
    assert_eq!(refused.code, TermErrorCode::NotFound, "{refused:?}");

    let pane = pane_id(&agent.ok("pane_split", json!({})).await);
    agent.ok("pane_close", json!({ "pane": pane })).await;
    let again = agent.ok("pane_close", json!({ "pane": pane })).await;
    assert_eq!(again["alreadyClosed"], true, "{again}");
}

#[tokio::test(flavor = "multi_thread")]
async fn refusals_say_why_in_the_error_itself() {
    let Setup {
        agent,
        _dir,
        _daemon,
        ..
    } = setup(|_| {}).await;
    let tab = agent.ok("tab_new", json!({})).await;
    let only = pane_id(&tab);
    let refused = refusal(&agent, "pane_float", json!({ "pane": only })).await;
    assert_ne!(refused.message, "Invalid", "{refused:?}");
    assert!(
        refused.message.contains(&only) && refused.message.contains("in place"),
        "{refused:?}"
    );
}

/// Each agent may hold 32 panes of its own; all agents of a session together 128, a quarter
/// of macOS's default 511 pseudo-terminals, so a runaway tree of workers leaves the host
/// room for the user's own terminals. The test lowers the session cap to keep it fast.
#[tokio::test(flavor = "multi_thread")]
async fn agents_share_a_session_cap_well_under_the_hosts_pty_limit() {
    let Setup {
        agent,
        agent_pane,
        _dir,
        _daemon,
        ..
    } = setup(|config| config.agent_panes_per_session = 6).await;
    let worker = pane_id(&agent.ok("tab_new", json!({})).await);
    let worker = agent.clone_as(worker.trim_start_matches('p').to_owned());
    for _ in 0..5 {
        worker.ok("tab_new", json!({})).await;
    }
    let refused = refusal(&worker, "tab_new", json!({})).await;
    assert_eq!(refused.code, TermErrorCode::Forbidden, "{refused:?}");
    assert!(
        refused.message.contains("5 of them yours")
            && refused.message.contains("6 of 6")
            && refused.message.contains(&format!("p{}", agent_pane.0)),
        "{refused:?}"
    );

    let who = worker.ok("whoami", json!({})).await;
    assert_eq!(
        who["limits"]["panes"],
        json!({ "yours": { "open": 5, "max": 32 }, "session": { "open": 6, "max": 6 } }),
        "{who}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn pane_list_groups_panes_by_tab() {
    let Setup {
        mut user,
        agent_pane,
        agent,
        _dir,
        _daemon,
        ..
    } = setup(|_| {}).await;
    let me = format!("p{}", agent_pane.0);
    let home = user.tab().tab_id;
    let home_tab = format!("t{}", home.0);
    let session = user.layout.as_ref().unwrap().session_id;
    user.op(LayoutOp::PutProject {
        session_id: session,
        project: Project {
            id: "api".into(),
            name: "API".into(),
            color: 1,
            order: 0,
            updated: UnixMillis(10),
        },
    })
    .await;
    user.op(LayoutOp::SetTabProject {
        tab_id: home,
        project: Some("api".into()),
        rank: 0,
    })
    .await;

    let split = pane_id(&agent.ok("pane_split", json!({})).await);
    let window = pane_id(
        &agent
            .ok(
                "pane_split",
                json!({ "float": true, "frame": { "x": 0.5, "y": 0.1, "w": 0.4, "h": 0.5 } }),
            )
            .await,
    );
    let titled = agent.ok("tab_new", json!({ "title": "build" })).await;
    let titled_tab = titled["tab"].as_str().unwrap().to_owned();
    agent
        .ok(
            "pane_send",
            json!({ "pane": pane_id(&titled), "text": "printf '\\033]0;not the title\\007'", "submit": true }),
        )
        .await;

    let list = agent.ok("pane_list", json!({})).await;
    let home_listing = tab_listing(&list, &home_tab);
    assert_eq!(home_listing["project"]["id"], "api", "{list}");
    assert_eq!(home_listing["project"]["name"], "API", "{list}");
    assert_eq!(home_listing["focused"], me, "{list}");
    assert_eq!(home_listing["active"], true, "{list}");
    assert_eq!(home_listing["tree"]["split"], "horizontal", "{list}");
    assert_eq!(home_listing["tree"]["ratio"], 0.5, "{list}");
    assert_eq!(home_listing["tree"]["first"], me, "{list}");
    assert_eq!(home_listing["tree"]["second"], split, "{list}");
    assert_eq!(
        home_listing["floats"][0]["panes"],
        json!([window]),
        "{list}"
    );
    assert_eq!(home_listing["floats"][0]["frame"]["x"], 0.5, "{list}");
    assert_eq!(
        home_listing["panes"],
        json!([me, split, window]),
        "every pane of the tab, floats included: {list}"
    );
    assert!(
        list["panes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|pane| pane["id"] == split && pane["tab"] == home_tab),
        "the flat listing stays: {list}"
    );

    let titled_pane = pane_id(&titled);
    let deadline = std::time::Instant::now() + crate::support::TIMEOUT;
    loop {
        let list = agent.ok("pane_list", json!({ "tab": titled_tab })).await;
        let pane_title = list["panes"][0]["title"].as_str().unwrap_or_default();
        if pane_title == "not the title" {
            assert_eq!(tab_listing(&list, &titled_tab)["title"], "build", "{list}");
            assert_eq!(list["tabs"].as_array().unwrap().len(), 1, "{list}");
            assert_eq!(list["panes"][0]["id"], titled_pane, "{list}");
            break;
        }
        assert!(std::time::Instant::now() < deadline, "no title: {list}");
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }

    let mine = agent.ok("pane_list", json!({ "scope": "mine" })).await;
    let ids: Vec<&str> = mine["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].as_str().unwrap())
        .collect();
    assert_eq!(
        ids,
        [split.as_str(), window.as_str(), titled_pane.as_str()],
        "{mine}"
    );
}
