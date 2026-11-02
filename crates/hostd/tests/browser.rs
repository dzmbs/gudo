//! The real `BROWSER` helper (`gudo-hook open-url`) against a daemon in this process: a program
//! in a pane opens a URL the way `claude /login` does (`$BROWSER <url>`, success on exit 0)
//! and the app showing the pane is asked to open it.

#[allow(dead_code)]
#[path = "../../daemon/tests/it/support.rs"]
mod support;

use client_core::ClientConfig;
use client_core::proto::BrowserPush;

use support::{TestClient, start_with, ticket};

const HELPER: &str = env!("CARGO_BIN_EXE_gudo-hook");

#[tokio::test(flavor = "multi_thread")]
async fn browser_urls_reach_the_app() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = start_with(dir.path(), |c| c.hook_bin = Some(HELPER.into())).await;
    let mut app = TestClient::connect_browser(&ticket(&daemon), ClientConfig::generate_key());
    let pane = app.attach_and_follow().await;

    let url = "https://claude.ai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A40123%2Fcallback&state=s";
    app.type_line(
        pane,
        &format!("\"$BROWSER\" '{url}' && echo \"opener exit $?\""),
    );
    app.until("the URL", |c| !c.browser.is_empty()).await;
    assert_eq!(
        app.browser[0],
        BrowserPush::Open {
            pane_id: pane,
            url: url.into()
        }
    );
    app.wait_text(pane, "opener exit 0").await;
}
