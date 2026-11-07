use super::*;

#[test]
fn attaching_queues_reconciliation_without_another_file_or_agent_event() {
    let root = tempfile::tempdir().unwrap();
    let (wake, mut wakes) = mpsc::channel(1);
    let watch = NativeWatch::new(root.path(), wake).unwrap();
    assert!(wakes.try_recv().is_ok());
    assert!(watch.check().is_ok());
}

#[test]
fn backend_failure_is_sticky_even_when_a_successful_wake_already_fills_the_slot() {
    let (wake, mut wakes) = mpsc::channel(1);
    let failed = AtomicBool::new(false);
    wake.try_send(()).unwrap();
    deliver(
        Err(notify::Error::generic("fixture backend failure")),
        &failed,
        &wake,
    );
    assert!(failed.load(Ordering::Acquire));
    assert!(wakes.try_recv().is_ok());
    deliver(
        Ok(notify::Event::new(notify::EventKind::Any)),
        &failed,
        &wake,
    );
    assert!(failed.load(Ordering::Acquire));
    assert!(wakes.try_recv().is_ok());
}

#[test]
fn read_observations_do_not_wake_the_reader_back_into_itself() {
    let (wake, mut wakes) = mpsc::channel(1);
    let failed = AtomicBool::new(false);
    for access in [
        AccessKind::Read,
        AccessKind::Open(AccessMode::Any),
        AccessKind::Close(AccessMode::Read),
    ] {
        deliver(
            Ok(notify::Event::new(notify::EventKind::Access(access))),
            &failed,
            &wake,
        );
        assert!(matches!(
            wakes.try_recv(),
            Err(mpsc::error::TryRecvError::Empty)
        ));
    }
    deliver(
        Ok(notify::Event::new(notify::EventKind::Access(
            AccessKind::Close(AccessMode::Write),
        ))),
        &failed,
        &wake,
    );
    assert!(wakes.try_recv().is_ok());
    deliver(
        Ok(notify::Event::new(notify::EventKind::Modify(
            notify::event::ModifyKind::Any,
        ))),
        &failed,
        &wake,
    );
    assert!(wakes.try_recv().is_ok());
    assert!(!failed.load(Ordering::Acquire));
}
