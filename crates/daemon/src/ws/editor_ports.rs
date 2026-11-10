//! A loopback port per editor folder that survives restarts, and so does the workbench's origin.

use std::collections::{BTreeMap, HashSet};
use std::io;
use std::net::TcpListener;
use std::ops::RangeInclusive;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use crate::{fsutil, loopback_port};

const PORT_RANGE: RangeInclusive<u16> = 20000..=29999;

pub(crate) struct EditorPorts {
    path: PathBuf,
    assigned: Mutex<BTreeMap<String, u16>>,
    /// Keeps the file's writes in order, so the last one holds the newest ports.
    saving: tokio::sync::Mutex<()>,
}

impl EditorPorts {
    /// Loads the saved ports, forgetting those of folders that are gone.
    pub(crate) fn load(path: PathBuf) -> Self {
        let mut assigned: BTreeMap<String, u16> = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        assigned.retain(|folder, _| Path::new(folder).is_dir());
        Self {
            path,
            assigned: Mutex::new(assigned),
            saving: tokio::sync::Mutex::new(()),
        }
    }

    /// Binds the folder's port, or a new one (kept for next time) when it stays taken.
    pub(crate) async fn bind(&self, folder: &str) -> io::Result<TcpListener> {
        let saved = self.assigned().get(folder).copied();
        if let Some(port) = saved
            && let Ok(listener) = loopback_port::bind_saved(port, bind).await
        {
            return Ok(listener);
        }
        let listener = {
            let mut assigned = self.assigned();
            let taken: HashSet<u16> = assigned.values().copied().collect();
            let listener =
                loopback_port::bind_new(&PORT_RANGE, |port| taken.contains(&port), bind)?;
            assigned.insert(folder.to_owned(), listener.local_addr()?.port());
            listener
        };
        if let Err(error) = self.save().await {
            tracing::warn!("saving editor ports: {error}");
        }
        Ok(listener)
    }

    fn assigned(&self) -> std::sync::MutexGuard<'_, BTreeMap<String, u16>> {
        self.assigned.lock().unwrap_or_else(PoisonError::into_inner)
    }

    async fn save(&self) -> io::Result<()> {
        let _saving = self.saving.lock().await;
        let bytes = serde_json::to_vec(&*self.assigned()).map_err(io::Error::other)?;
        let path = self.path.clone();
        tokio::task::spawn_blocking(move || fsutil::write_atomic(&path, &bytes))
            .await
            .map_err(io::Error::other)?
    }
}

fn bind(port: u16) -> io::Result<TcpListener> {
    TcpListener::bind(("127.0.0.1", port))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn port(listener: &TcpListener) -> u16 {
        listener.local_addr().unwrap().port()
    }

    fn folder(root: &Path, name: &str) -> String {
        let folder = root.join(name);
        std::fs::create_dir_all(&folder).unwrap();
        folder.to_string_lossy().into_owned()
    }

    #[tokio::test]
    async fn a_folder_keeps_its_port_across_restarts() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("ports.json");
        let app = folder(temp.path(), "app");
        let first = port(&EditorPorts::load(path.clone()).bind(&app).await.unwrap());
        assert!(PORT_RANGE.contains(&first));
        let again = port(&EditorPorts::load(path).bind(&app).await.unwrap());
        assert_eq!(again, first);
    }

    #[tokio::test]
    async fn a_port_its_last_server_is_letting_go_of_is_kept() {
        let temp = tempfile::tempdir().unwrap();
        let ports = EditorPorts::load(temp.path().join("ports.json"));
        let app = folder(temp.path(), "app");
        let stopping = ports.bind(&app).await.unwrap();
        let kept = port(&stopping);
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(300));
            drop(stopping);
        });
        assert_eq!(port(&ports.bind(&app).await.unwrap()), kept);
    }

    #[test]
    fn folders_that_are_gone_lose_their_ports() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("ports.json");
        let app = folder(temp.path(), "app");
        let gone = temp.path().join("gone").to_string_lossy().into_owned();
        let saved = BTreeMap::from([(app.clone(), 20001), (gone, 20002)]);
        std::fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
        let ports = EditorPorts::load(path);
        assert_eq!(*ports.assigned(), BTreeMap::from([(app, 20001)]));
    }

    #[tokio::test]
    async fn folders_get_their_own_ports_and_a_taken_one_is_replaced() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("ports.json");
        let (app, site) = (folder(temp.path(), "app"), folder(temp.path(), "site"));
        let ports = EditorPorts::load(path.clone());
        let app_listener = ports.bind(&app).await.unwrap();
        let site_port = port(&ports.bind(&site).await.unwrap());
        assert_ne!(port(&app_listener), site_port);

        let replaced = port(&ports.bind(&app).await.unwrap());
        assert_ne!(
            replaced,
            port(&app_listener),
            "the first listener still holds it"
        );
        drop(app_listener);
        let reloaded = EditorPorts::load(path);
        assert_eq!(port(&reloaded.bind(&app).await.unwrap()), replaced);
    }
}
