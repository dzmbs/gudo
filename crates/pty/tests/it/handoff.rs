//! Handing a running PTY to a successor (`hand_off`, then `adopt` of the same descriptor and
//! child) as the daemon does across `exec`; here both ends are in one process, with the master
//! duplicated in place of the inherited descriptor.

use std::os::fd::{AsRawFd, BorrowedFd, OwnedFd};
use std::time::Duration;

use pty::{AdoptError, PtyActor, Seq};

use crate::support::{read_to_end, read_until, spawn, within};

fn inherited(master: i32) -> OwnedFd {
    // SAFETY: the old actor keeps `master` open until it is dropped.
    let borrowed = unsafe { BorrowedFd::borrow_raw(master) };
    rustix::io::dup(borrowed).expect("dup")
}

/// Whether `pid` is still an unreaped child of this process.
fn child_of_ours(pid: u32) -> bool {
    rustix::process::waitid(
        rustix::process::WaitId::Pid(rustix::process::Pid::from_raw(pid as i32).unwrap()),
        rustix::process::WaitIdOptions::EXITED
            | rustix::process::WaitIdOptions::NOHANG
            | rustix::process::WaitIdOptions::NOWAIT,
    )
    .is_ok()
}

fn cloexec(fd: &OwnedFd) -> bool {
    rustix::io::fcntl_getfd(fd)
        .unwrap()
        .contains(rustix::io::FdFlags::CLOEXEC)
}

#[tokio::test]
async fn a_pending_flush_does_not_claim_unsent_handoff_bytes_were_written() {
    let old = spawn(&[
        "/bin/sh",
        "-c",
        "stty raw -echo; echo ready; exec sleep 100",
    ]);
    let mut output = old.subscribe();
    read_until(&mut output, "ready").await;
    old.write(vec![b'x'; pty::MAX_QUEUED_INPUT]).await.unwrap();
    let flush = old.flush_writes();
    tokio::pin!(flush);
    tokio::select! {
        result = &mut flush => panic!("flush finished without a reader: {result:?}"),
        () = tokio::time::sleep(Duration::from_millis(20)) => {}
    }
    let handed = old.hand_off().unwrap();
    assert!(!handed.unsent_input.is_empty());
    assert!(within("handoff flush refused", flush).await.is_err());
    let new = PtyActor::adopt(inherited(handed.master), &handed, None).unwrap();
    new.signal(pty::Signal::Kill).unwrap();
    within("successor child reaped", new.wait()).await.unwrap();
}

#[tokio::test]
async fn the_successor_continues_output_input_and_history() {
    let old = spawn(&[
        "/bin/sh",
        "-c",
        "echo first; read line; echo \"got:$line\"; i=0; while [ $i -lt 400 ]; do i=$((i+1)); echo n=$i; done; read done; echo \"bye:$done\"",
    ]);
    let mut output = old.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut output, "first").await;
    let pid = old.pid();

    let handed = old.hand_off().unwrap();
    assert!(
        old.try_write("late\n").is_err(),
        "writes stop at the hand-off"
    );
    assert_eq!(handed.pid, pid);
    assert_eq!(handed.head, old.head());
    assert!(handed.exit_status.is_none());
    let before = old.read_from(Seq::ZERO).unwrap().data;

    let mut handed = handed;
    handed.unsent_input = b"hello\n".to_vec();
    let master = inherited(handed.master);
    drop(old);
    let new = PtyActor::adopt(master, &handed, None).unwrap();
    assert_eq!(new.pid(), pid);
    assert_eq!(new.read_from(Seq::ZERO).unwrap().data, before);

    let mut output = new.subscribe_from(handed.head).unwrap();
    read_until(&mut output, "got:hello").await;
    read_until(&mut output, "n=400\r\n").await;
    new.write("end\n").await.unwrap();
    let rest = read_to_end(&mut output).await;
    assert!(rest.contains("bye:end"), "{rest:?}");
    let status = within("exit", new.wait()).await.unwrap();
    assert!(status.success(), "{status:?}");
    // Every offset from the start is the old stream continued.
    let all = new.read_from(Seq::ZERO).unwrap().data;
    let text = String::from_utf8_lossy(&all);
    let numbers: Vec<u32> = text
        .lines()
        .filter_map(|line| line.trim().strip_prefix("n=")?.parse().ok())
        .collect();
    assert_eq!(numbers, (1..=400).collect::<Vec<_>>());
}

#[tokio::test]
async fn a_child_that_exits_during_the_hand_off_is_reaped_by_the_successor() {
    let old = spawn(&["/bin/sh", "-c", "read line; exit 7"]);
    let handed = old.hand_off().unwrap();
    let master = inherited(handed.master);
    drop(old);
    let new = PtyActor::adopt(master, &handed, None).unwrap();
    new.write("go\n").await.unwrap();
    let status = within("exit", new.wait()).await.unwrap();
    assert_eq!(status.code(), Some(7));
}

#[tokio::test]
async fn an_exit_seen_before_the_hand_off_is_carried() {
    let old = spawn(&["/bin/sh", "-c", "exit 3"]);
    within("exit", old.wait()).await.unwrap();
    let handed = old.hand_off().unwrap();
    assert!(handed.exit_status.is_some());
    let master = inherited(handed.master);
    drop(old);
    let new = PtyActor::adopt(master, &handed, None).unwrap();
    assert_eq!(within("exit", new.wait()).await.unwrap().code(), Some(3));
    assert!(
        new.signal(pty::Signal::Kill).is_err(),
        "a reaped pid is never signalled"
    );
}

#[tokio::test]
async fn adoption_refuses_strangers() {
    let old = spawn(&["/bin/sleep", "30"]);
    let handed = old.hand_off().unwrap();

    // A process that is not ours is refused and never signalled.
    let mut not_ours = handed.clone();
    not_ours.pid = std::os::unix::process::parent_id();
    assert!(matches!(
        PtyActor::adopt(inherited(handed.master), &not_ours, None),
        Err(AdoptError::NotAChild(_))
    ));
    not_ours.pid = 1;
    assert!(matches!(
        PtyActor::adopt(inherited(handed.master), &not_ours, None),
        Err(AdoptError::NotAChild(_))
    ));
    assert!(child_of_ours(handed.pid), "the real child is untouched");

    // A child of ours that cannot be continued ends rather than running on unseen.
    let first = spawn(&["/bin/sleep", "30"]);
    let not_a_master = first.hand_off().unwrap();
    let (read, _write) = rustix::pipe::pipe().unwrap();
    assert!(matches!(
        PtyActor::adopt(read, &not_a_master, None),
        Err(AdoptError::NotAMaster(_))
    ));
    let second = spawn(&["/bin/sleep", "30"]);
    let mut torn = second.hand_off().unwrap();
    torn.head = Seq::new(torn.head.get() + 5);
    assert!(matches!(
        PtyActor::adopt(inherited(torn.master), &torn, None),
        Err(AdoptError::Ring)
    ));
    within("children that cannot be adopted end", async {
        while child_of_ours(not_a_master.pid) || child_of_ours(torn.pid) {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;

    let master = inherited(handed.master);
    assert!(!cloexec(&master));
    let new = PtyActor::adopt(master, &handed, None).unwrap();
    drop(old);
    let adopted = new.hand_off().unwrap();
    // SAFETY: `new` keeps the descriptor open.
    let master = unsafe { BorrowedFd::borrow_raw(adopted.master) };
    assert!(
        rustix::io::fcntl_getfd(master)
            .unwrap()
            .contains(rustix::io::FdFlags::CLOEXEC),
        "an adopted master is close-on-exec again"
    );
    pty::abandon(inherited(adopted.master), adopted.pid, Duration::ZERO);
}

#[tokio::test]
async fn abandoning_ends_even_a_program_that_ignores_the_hangup() {
    let old = spawn(&[
        "/bin/sh",
        "-c",
        "trap '' HUP; echo ready; while :; do sleep 1; done",
    ]);
    let mut output = old.subscribe_from(Seq::ZERO).unwrap();
    read_until(&mut output, "ready").await;
    let pid = old.pid() as i32;
    let handed = old.hand_off().unwrap();
    let master = inherited(handed.master);
    drop(old);
    assert!(master.as_raw_fd() > 2);
    pty::abandon(master, handed.pid, Duration::from_millis(200));
    within("the abandoned child is gone", async {
        // Reaped by the abandon thread: the pid no longer names a child of ours.
        while rustix::process::waitid(
            rustix::process::WaitId::Pid(rustix::process::Pid::from_raw(pid).unwrap()),
            rustix::process::WaitIdOptions::EXITED
                | rustix::process::WaitIdOptions::NOHANG
                | rustix::process::WaitIdOptions::NOWAIT,
        )
        .is_ok()
        {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await;
}
