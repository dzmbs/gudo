use std::io;

pub(super) fn pid(stream: &tokio::net::UnixStream) -> io::Result<u32> {
    let credentials = stream.peer_cred()?;
    if credentials.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "wrong Codex socket peer",
        ));
    }
    credentials
        .pid()
        .and_then(|pid| u32::try_from(pid).ok())
        .filter(|pid| *pid > 1)
        .ok_or_else(|| io::Error::other("Codex socket peer identity unavailable"))
}

pub(super) async fn in_tree(peer: u32, root: u32) -> bool {
    tokio::task::spawn_blocking(move || crate::procinfo::process_tree(root).contains(&peer))
        .await
        .unwrap_or(false)
}
