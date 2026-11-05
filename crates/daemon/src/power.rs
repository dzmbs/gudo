use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use proto::{PowerPolicy, PowerStatus};
use tokio::sync::Notify;

use crate::core::{Core, lock};

pub(crate) struct Power {
    path: PathBuf,
    state: Mutex<PowerStatus>,
    pub changed: Notify,
}

impl Power {
    pub fn load(directory: &Path) -> Self {
        let path = directory.join("power-policy.json");
        let policy = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Self {
            path,
            state: Mutex::new(PowerStatus {
                policy,
                keeping_awake: false,
            }),
            changed: Notify::new(),
        }
    }

    pub fn settings(&self, policy: Option<PowerPolicy>) -> std::io::Result<PowerStatus> {
        let mut state = lock(&self.state);
        if let Some(policy) = policy {
            let bytes = serde_json::to_vec(&policy)?;
            crate::fsutil::write_atomic(&self.path, &bytes)?;
            state.policy = policy;
            self.changed.notify_one();
        }
        Ok(*state)
    }
}

fn should_inhibit(policy: PowerPolicy, working: bool, plugged_in: bool) -> bool {
    working
        && match policy {
            PowerPolicy::Always => true,
            PowerPolicy::WhenPluggedIn => plugged_in,
            PowerPolicy::Never => false,
        }
}

pub(crate) async fn run(core: Arc<Core>) {
    let mut assertion = None;
    loop {
        let working = core.pane_entries().iter().any(|(_, entry)| {
            lock(&entry.agent)
                .as_ref()
                .is_some_and(|agent| agent.state() == agents::AgentState::Working)
        });
        let policy = lock(&core.power.state).policy;
        if assertion
            .as_mut()
            .is_some_and(|assertion: &mut platform::Assertion| !assertion.is_active())
        {
            assertion = None;
        }
        if should_inhibit(policy, working, working && platform::plugged_in()) {
            if assertion.is_none() {
                assertion = platform::Assertion::acquire();
            }
        } else {
            assertion = None;
        }
        lock(&core.power.state).keeping_awake = assertion.is_some();
        tokio::select! {
            () = core.power.changed.notified() => {},
            () = tokio::time::sleep(Duration::from_secs(2)), if working => {},
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::ffi::{c_char, c_void};
    type Reference = *const c_void;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithCString(
            allocator: Reference,
            text: *const c_char,
            encoding: u32,
        ) -> Reference;
        fn CFRelease(reference: Reference);
        fn CFEqual(first: Reference, second: Reference) -> bool;
    }

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPMAssertionCreateWithName(
            kind: Reference,
            level: u32,
            name: Reference,
            identifier: *mut u32,
        ) -> i32;
        fn IOPMAssertionRelease(identifier: u32) -> i32;
        fn IOPSCopyPowerSourcesInfo() -> Reference;
        fn IOPSGetProvidingPowerSourceType(info: Reference) -> Reference;
    }

    pub struct Assertion(u32);

    impl Assertion {
        pub fn is_active(&mut self) -> bool {
            true
        }

        pub fn acquire() -> Option<Self> {
            // SAFETY: The strings are NUL-terminated UTF-8; every owned CF object is released.
            unsafe {
                let kind = CFStringCreateWithCString(
                    std::ptr::null(),
                    c"PreventUserIdleSystemSleep".as_ptr(),
                    0x08000100,
                );
                let name = CFStringCreateWithCString(
                    std::ptr::null(),
                    c"Agents are working".as_ptr(),
                    0x08000100,
                );
                if kind.is_null() || name.is_null() {
                    if !kind.is_null() {
                        CFRelease(kind);
                    }
                    if !name.is_null() {
                        CFRelease(name);
                    }
                    return None;
                }
                let mut identifier = 0;
                let result = IOPMAssertionCreateWithName(kind, 255, name, &mut identifier);
                CFRelease(kind);
                CFRelease(name);
                (result == 0).then_some(Self(identifier))
            }
        }
    }

    impl Drop for Assertion {
        fn drop(&mut self) {
            // SAFETY: This is the assertion ID returned by a successful create, released once.
            unsafe {
                IOPMAssertionRelease(self.0);
            }
        }
    }

    pub fn plugged_in() -> bool {
        // SAFETY: The source type is borrowed from info and compared before releasing info.
        unsafe {
            let info = IOPSCopyPowerSourcesInfo();
            if info.is_null() {
                return false;
            }
            let source = IOPSGetProvidingPowerSourceType(info);
            let ac = CFStringCreateWithCString(std::ptr::null(), c"AC Power".as_ptr(), 0x08000100);
            let plugged_in = !source.is_null() && !ac.is_null() && CFEqual(source, ac);
            if !ac.is_null() {
                CFRelease(ac);
            }
            CFRelease(info);
            plugged_in
        }
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::process::{Child, Command, Stdio};

    pub struct Assertion(Child);

    impl Assertion {
        pub fn is_active(&mut self) -> bool {
            matches!(self.0.try_wait(), Ok(None))
        }

        pub fn acquire() -> Option<Self> {
            Command::new("systemd-inhibit")
                .args([
                    "--what=idle",
                    "--mode=block",
                    "--who",
                    brand::PRODUCT_NAME,
                    "--why=Agents are working",
                    "/bin/cat",
                ])
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .ok()
                .map(Self)
        }
    }

    impl Drop for Assertion {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    pub fn plugged_in() -> bool {
        let Ok(entries) = std::fs::read_dir("/sys/class/power_supply") else {
            return false;
        };
        let mut battery = false;
        for entry in entries.flatten() {
            let directory = entry.path();
            battery |= std::fs::read_to_string(directory.join("type"))
                .is_ok_and(|kind| kind.trim() == "Battery");
            if std::fs::read_to_string(directory.join("online"))
                .is_ok_and(|online| online.trim() == "1")
            {
                return true;
            }
        }
        !battery
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_working_agents_inhibit_under_the_selected_policy() {
        for working in [false, true] {
            for plugged_in in [false, true] {
                assert_eq!(
                    should_inhibit(PowerPolicy::Always, working, plugged_in),
                    working
                );
                assert!(!should_inhibit(PowerPolicy::Never, working, plugged_in));
                assert_eq!(
                    should_inhibit(PowerPolicy::WhenPluggedIn, working, plugged_in),
                    working && plugged_in
                );
            }
        }
    }

    #[test]
    fn policy_defaults_to_plugged_in_and_survives_reload() {
        let directory = tempfile::tempdir().unwrap();
        let power = Power::load(directory.path());
        assert_eq!(
            power.settings(None).unwrap().policy,
            PowerPolicy::WhenPluggedIn
        );
        power.settings(Some(PowerPolicy::Always)).unwrap();
        assert_eq!(
            Power::load(directory.path()).settings(None).unwrap().policy,
            PowerPolicy::Always
        );
    }
}
