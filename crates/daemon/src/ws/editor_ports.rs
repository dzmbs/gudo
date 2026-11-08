//! A loopback port per editor folder that survives restarts, and so does the workbench's origin.

use std::collections::{BTreeMap, HashSet};
use std::io;
use std::net::TcpListener;
use std::ops::RangeInclusive;
use std::path::PathBuf;
use std::sync::Mutex;

use crate::fsutil;

/// Below the ephemeral ranges of macOS (49152+) and Linux (32768+).
const PORT_RANGE: RangeInclusive<u16> = 20000..=29999;
const ATTEMPTS: usize = 32;

pub(crate) struct EditorPorts {
    path: PathBuf,
    assigned: Mutex<BTreeMap<String, u16>>,
}

impl EditorPorts {
    pub(crate) fn load(path: PathBuf) -> Self {
        let assigned = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            path,
            assigned: Mutex::new(assigned),
        }
    }

    /// Binds the folder's port, or a new one (kept for next time) when it is taken.
    pub(crate) fn bind(&self, folder: &str) -> io::Result<TcpListener> {
        let mut assigned = self
            .assigned
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(listener) = assigned.get(folder).and_then(|&port| bind(port).ok()) {
            return Ok(listener);
        }
        let taken: HashSet<u16> = assigned.values().copied().collect();
        let listener = match (0..ATTEMPTS)
            .map(|_| random_port())
            .filter(|port| !taken.contains(port))
            .find_map(|port| bind(port).ok())
        {
            Some(listener) => listener,
            None => bind(0)?,
        };
        assigned.insert(folder.to_owned(), listener.local_addr()?.port());
        let saved = serde_json::to_vec(&*assigned)
            .map_err(io::Error::other)
            .and_then(|bytes| fsutil::write_atomic(&self.path, &bytes));
        if let Err(error) = saved {
            tracing::warn!("saving editor ports: {error}");
        }
        Ok(listener)
    }
}

fn bind(port: u16) -> io::Result<TcpListener> {
    TcpListener::bind(("127.0.0.1", port))
}

fn random_port() -> u16 {
    let span = PORT_RANGE.end() - PORT_RANGE.start() + 1;
    PORT_RANGE.start() + u16::from_le_bytes(fsutil::random::<2>()) % span
}

#[cfg(test)]
mod tests {
    use super::*;

    fn port(listener: &TcpListener) -> u16 {
        listener.local_addr().unwrap().port()
    }

    #[test]
    fn a_folder_keeps_its_port_across_restarts() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("ports.json");
        let first = port(&EditorPorts::load(path.clone()).bind("/src/app").unwrap());
        assert!(PORT_RANGE.contains(&first));
        let again = port(&EditorPorts::load(path).bind("/src/app").unwrap());
        assert_eq!(again, first);
    }

    #[test]
    fn folders_get_their_own_ports_and_a_taken_one_is_replaced() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("ports.json");
        let ports = EditorPorts::load(path.clone());
        let app = ports.bind("/src/app").unwrap();
        let site = port(&ports.bind("/src/site").unwrap());
        assert_ne!(port(&app), site);

        let replaced = port(&ports.bind("/src/app").unwrap());
        assert_ne!(replaced, port(&app), "the first listener still holds it");
        drop(app);
        let reloaded = EditorPorts::load(path);
        assert_eq!(port(&reloaded.bind("/src/app").unwrap()), replaced);
    }
}
