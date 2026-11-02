use std::time::Duration;

use pty::{ForegroundProcess, PtyActor, Seq};

use crate::support::{command, read_until, within};

async fn wait_foreground(pty: &PtyActor, name: &str) -> ForegroundProcess {
    within(&format!("foreground {name}"), async {
        loop {
            if let Some(foreground) = pty.foreground_process()
                && foreground.name == name
            {
                return foreground;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
}

#[tokio::test]
async fn reports_shell_then_job() {
    let mut command = command(&["/bin/bash", "--norc", "--noprofile", "-i"]);
    command.env("PS1", "PROMPT> ");
    let pty = PtyActor::spawn(command, pty::SpawnOptions::default()).unwrap();
    let mut output = pty.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut output, "PROMPT> ").await;

    let shell = wait_foreground(&pty, "bash").await;
    assert_eq!(shell.pid, pty.pid());
    assert_eq!(shell.program(), "bash");

    // Job control puts the job in its own foreground process group.
    pty.write("(exec -a my-sleeper /bin/sleep 30)\n")
        .await
        .unwrap();
    let job = wait_foreground(&pty, "sleep").await;
    assert_ne!(job.pid, pty.pid());
    assert_eq!(job.argv, ["my-sleeper", "30"]);
    assert_eq!(job.program(), "my-sleeper");

    pty.write("\x03").await.unwrap(); // ^C the job
    let shell = wait_foreground(&pty, "bash").await;
    assert_eq!(shell.pid, pty.pid());
    pty.write("exit\n").await.unwrap();
    within("exit", pty.wait()).await.unwrap();
}
