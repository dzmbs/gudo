//! Floating windows: pushed after every layout to everyone who sees them, arranged only by
//! drivers, cut down to a guest's scope, kept across restarts, and invisible to the layout
//! itself so older clients keep the pane as a split.

use client_core::proto::{
    Axis, CloseWhen, Direction, DockTarget, FloatFrame, LayoutOp, OpError, OpOutcome, PaneLaunch,
    Roles, Scope, UnixMillis,
};
use client_core::{ClientConfig, grants::GrantSpec, now_millis};

use crate::support::{TestClient, leaves, start, ticket};

fn forbidden(outcome: OpOutcome) -> bool {
    matches!(
        outcome,
        OpOutcome::Failed {
            code: OpError::Forbidden,
            ..
        }
    )
}

async fn invite(owner: &TestClient, roles: Roles, scope: Scope) -> TestClient {
    let mut spec = GrantSpec::new(roles, scope);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "guest".into())
        .await
        .unwrap();
    let mut guest = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    guest.client.attach(None);
    guest.until("guest layout", |c| c.layout.is_some()).await;
    guest
}

#[tokio::test(flavor = "multi_thread")]
async fn drivers_arrange_floats_everyone_in_scope_sees_them() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let key = ClientConfig::generate_key();
    let mut owner = TestClient::connect(&ticket(&daemon), key.clone());
    let first = owner.attach_and_follow().await;
    let session = owner.layout.as_ref().unwrap().session_id;
    let OpOutcome::PaneCreated { pane_id: second } = owner
        .op(LayoutOp::Split {
            pane_id: first,
            axis: Axis::Horizontal,
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("no split");
    };
    let tree = owner.tab().root.clone();

    let mut viewer = invite(&owner, Roles::VIEWER, Scope::Daemon).await;
    let frame = FloatFrame {
        x: 0.5,
        y: 0.1,
        w: 0.4,
        h: 0.5,
    };
    let refused = [
        LayoutOp::FloatPane {
            pane_id: second,
            frame: None,
        },
        LayoutOp::NewFloat {
            pane_id: first,
            launch: PaneLaunch::Shell { cwd: None },
            frame: None,
            focus: false,
            close: CloseWhen::Never,
        },
    ];
    for op in refused {
        assert!(forbidden(viewer.op(op).await), "a viewer cannot float");
    }

    assert_eq!(
        owner
            .op(LayoutOp::FloatPane {
                pane_id: second,
                frame: Some(frame),
            })
            .await,
        OpOutcome::Done
    );
    let pushed = owner.floats.last().expect("floats pushed").clone();
    assert_eq!(pushed.session_id, session);
    assert_eq!(pushed.revision, owner.layout.as_ref().unwrap().revision);
    assert_eq!(pushed.floats.len(), 1);
    assert_eq!(pushed.floats[0].panes, [second]);
    assert_eq!(pushed.floats[0].frame, frame);
    assert_eq!(
        owner.tab().root,
        tree,
        "the layout keeps the pane as a split"
    );

    viewer
        .until("the float", |c| {
            c.floats.last().is_some_and(|f| f.floats.len() == 1)
        })
        .await;
    for op in [
        LayoutOp::SetFloat {
            pane_id: second,
            frame: Some(FloatFrame { x: 0.0, ..frame }),
            minimized: None,
            pinned: None,
        },
        LayoutOp::DockPane {
            pane_id: second,
            beside: Some(DockTarget {
                pane_id: first,
                side: Direction::Down,
            }),
        },
    ] {
        assert!(
            forbidden(viewer.op(op).await),
            "a viewer cannot move a float"
        );
    }

    // A tab-scoped driver sees its own tab's windows, never another tab's.
    let OpOutcome::TabCreated {
        tab_id: other,
        pane_id: there,
    } = owner
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("no tab");
    };
    let OpOutcome::PaneCreated { pane_id: theirs } = owner
        .op(LayoutOp::NewFloat {
            pane_id: there,
            launch: PaneLaunch::Shell { cwd: None },
            frame: None,
            focus: false,
            close: CloseWhen::Never,
        })
        .await
    else {
        panic!("no float");
    };
    assert_eq!(owner.floats.last().unwrap().floats.len(), 2);
    let mut carol = invite(&owner, Roles::DRIVER, Scope::Tab(other)).await;
    carol.until("scoped floats", |c| !c.floats.is_empty()).await;
    let seen = carol.floats.last().unwrap();
    assert_eq!(seen.floats.len(), 1);
    assert_eq!(seen.floats[0].panes, [theirs]);
    assert_eq!(
        carol
            .op(LayoutOp::SetFloat {
                pane_id: theirs,
                frame: None,
                minimized: Some(true),
                pinned: None,
            })
            .await,
        OpOutcome::Done,
        "a driver arranges its tab's windows"
    );
    assert!(forbidden(
        carol
            .op(LayoutOp::SetFloat {
                pane_id: second,
                frame: None,
                minimized: Some(true),
                pinned: None,
            })
            .await
    ));

    // Floats come back after a restart, with the same ids.
    owner
        .until("the chip", |c| {
            c.floats
                .last()
                .is_some_and(|f| f.floats.iter().any(|w| w.minimized))
        })
        .await;
    let before = owner.floats.last().unwrap().floats.clone();
    drop((owner, viewer, carol));
    daemon.shutdown().await;
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), key);
    owner.client.attach(Some(session));
    owner.until("floats again", |c| !c.floats.is_empty()).await;
    assert_eq!(owner.floats.last().unwrap().floats, before);
    let tab = owner
        .layout
        .as_ref()
        .unwrap()
        .tabs
        .iter()
        .find(|t| leaves(&t.root).contains(&second))
        .expect("the pane is still in its tab")
        .clone();
    assert_eq!(leaves(&tab.root).len(), 2);
    daemon.shutdown().await;
}
