//! Projects: the owner groups tabs and hears every change; a guest can neither change nor
//! see them, whatever else it may drive.

use client_core::proto::{
    LayoutOp, OpError, OpOutcome, PaneLaunch, Project, Roles, Scope, TabProject, UnixMillis,
};
use client_core::{ClientConfig, grants::GrantSpec, now_millis};

use crate::support::{TestClient, start, ticket};

fn project(updated: u64) -> Project {
    Project {
        id: "web".into(),
        name: "Web".into(),
        color: 2,
        order: 0,
        updated: UnixMillis(updated),
    }
}

fn forbidden(outcome: OpOutcome) -> bool {
    matches!(
        outcome,
        OpOutcome::Failed {
            code: OpError::Forbidden,
            ..
        }
    )
}

#[tokio::test(flavor = "multi_thread")]
async fn only_the_owner_changes_and_sees_projects() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start(dir.path()).await;
    let mut owner = TestClient::connect(&ticket(&daemon), ClientConfig::generate_key());
    let pane = owner.attach_and_follow().await;
    let session = owner.layout.as_ref().unwrap().session_id;
    let tab = owner.tab().tab_id;

    let mut spec = GrantSpec::new(Roles::DRIVER, Scope::Daemon);
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .unwrap();
    let mut bob = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    bob.client.attach(None);
    bob.until("guest layout", |c| c.layout.is_some()).await;
    bob.follow(pane).await;

    let put = LayoutOp::PutProject {
        session_id: session,
        project: project(10),
    };
    let join = LayoutOp::SetTabProject {
        tab_id: tab,
        project: Some("web".into()),
        rank: 1,
    };
    assert!(forbidden(bob.op(put.clone()).await));
    assert!(forbidden(bob.op(join.clone()).await));

    assert_eq!(owner.op(put).await, OpOutcome::Done);
    assert_eq!(owner.op(join).await, OpOutcome::Done);
    let last = owner.projects.last().expect("projects pushed").clone();
    assert_eq!(last.session_id, session);
    assert_eq!(last.revision, owner.layout.as_ref().unwrap().revision);
    assert_eq!(last.projects, [project(10)]);
    assert_eq!(
        last.tabs,
        [TabProject {
            tab_id: tab,
            project: "web".into(),
            rank: 1,
        }]
    );

    // A rename after it, on the same ordered stream, proves the guest was sent none.
    assert_eq!(
        owner
            .op(LayoutOp::RenameTab {
                tab_id: tab,
                name: "after".into(),
            })
            .await,
        OpOutcome::Done
    );
    bob.until("the rename", |c| c.tab().name == "after").await;
    assert!(bob.projects.is_empty(), "{:?}", bob.projects);

    // An owner-role guest scoped to one tab sees only that tab's project.
    let OpOutcome::TabCreated { tab_id: other, .. } = owner
        .op(LayoutOp::NewTab {
            session_id: session,
            name: String::new(),
            launch: PaneLaunch::Shell { cwd: None },
        })
        .await
    else {
        panic!("no tab");
    };
    let api = Project {
        id: "api".into(),
        ..project(10)
    };
    for op in [
        LayoutOp::PutProject {
            session_id: session,
            project: api,
        },
        LayoutOp::SetTabProject {
            tab_id: other,
            project: Some("api".into()),
            rank: 0,
        },
    ] {
        assert_eq!(owner.op(op).await, OpOutcome::Done);
    }
    assert_eq!(owner.projects.last().unwrap().tabs.len(), 2);

    let mut spec = GrantSpec::new(Roles::OWNER, Scope::Tab(tab));
    spec.expires = Some(UnixMillis(now_millis().0 + 3_600_000));
    let invite = owner
        .client
        .create_invite(spec, "alice".into())
        .await
        .unwrap();
    let mut carol = TestClient::join(&invite.to_string(), ClientConfig::generate_key());
    carol.client.attach(None);
    carol
        .until("scoped projects", |c| !c.projects.is_empty())
        .await;
    let seen = carol.projects.last().unwrap();
    assert_eq!(seen.projects, [project(10)]);
    assert_eq!(seen.tabs.len(), 1);
    assert_eq!(seen.tabs[0].tab_id, tab);
}
