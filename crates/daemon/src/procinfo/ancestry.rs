#[derive(Debug)]
pub(super) struct Ancestor {
    pub pid: u32,
    pub is_daemon: bool,
    pub environment: Option<Vec<String>>,
}

pub(super) fn inherited_variable(
    name: &str,
    ancestors: impl IntoIterator<Item = Ancestor>,
) -> Option<String> {
    let mut boundary = None;
    for ancestor in ancestors {
        // A daemon can itself inherit another pane's credentials.
        if ancestor.is_daemon || boundary == Some(ancestor.pid) {
            return None;
        }
        let environment = ancestor.environment.as_ref()?;
        if let Some(marker) = environment_value(environment, brand::DAEMON_PID_ENV) {
            let host: std::num::NonZeroU32 = marker.parse().ok()?;
            if boundary.is_some_and(|boundary| boundary != host.get()) {
                return None;
            }
            boundary.get_or_insert(host.get());
            if boundary == Some(ancestor.pid) {
                return None;
            }
        }
        if foreign_pane_context(name, environment) {
            return None;
        }
        if let Some(value) = environment_value(environment, name) {
            return Some(value.to_owned());
        }
    }
    None
}

fn foreign_pane_context(name: &str, environment: &[String]) -> bool {
    let dev = name.starts_with(brand::DEV_ENV_PREFIX);
    let legacy = name.starts_with(brand::legacy::ENV_PREFIX);
    let release = name.starts_with(brand::RELEASE_ENV_PREFIX) && !dev;
    let current_prefix = if dev {
        brand::DEV_ENV_PREFIX
    } else if legacy {
        brand::legacy::ENV_PREFIX
    } else {
        brand::RELEASE_ENV_PREFIX
    };
    let foreign_prefix = if dev {
        brand::RELEASE_ENV_PREFIX
    } else {
        brand::DEV_ENV_PREFIX
    };
    (dev || release || legacy)
        && environment_value(environment, &format!("{current_prefix}PANE_ID")).is_none()
        && environment_value(environment, &format!("{foreign_prefix}PANE_ID")).is_some()
}

fn environment_value<'a>(environment: &'a [String], name: &str) -> Option<&'a str> {
    environment
        .iter()
        .find_map(|variable| variable.strip_prefix(name)?.strip_prefix('='))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ancestor(pid: u32, is_daemon: bool, variables: &[&str]) -> Ancestor {
        Ancestor {
            pid,
            is_daemon,
            environment: Some(
                variables
                    .iter()
                    .map(|variable| (*variable).to_owned())
                    .collect(),
            ),
        }
    }

    #[test]
    fn daemon_ancestors_never_supply_their_inherited_pane() {
        let parents = [
            ancestor(30, false, &[]),
            ancestor(20, true, &["GUDO_PANE_ID=private-parent-pane"]),
        ];
        assert_eq!(inherited_variable("GUDO_PANE_ID", parents), None);
    }

    #[test]
    fn a_foreign_flavour_pane_stops_discovery() {
        for (requested, foreign) in [
            ("GUDO_PANE_ID", "GUDO_DEV_PANE_ID=private-dev-pane"),
            ("GUDO_DEV_PANE_ID", "GUDO_PANE_ID=private-release-pane"),
            ("UN_PANE_ID", "GUDO_DEV_PANE_ID=private-dev-pane"),
        ] {
            let parents = [
                ancestor(30, false, &[foreign]),
                ancestor(20, false, &[&format!("{requested}=private-parent-pane")]),
            ];
            assert_eq!(inherited_variable(requested, parents), None, "{requested}");
        }
    }

    #[test]
    fn an_explicit_host_boundary_covers_renamed_and_embedded_daemons() {
        let parents = [
            ancestor(30, false, &["GUDO_DAEMON_PID=20"]),
            ancestor(20, false, &["GUDO_PANE_ID=private-parent-pane"]),
        ];
        assert_eq!(inherited_variable("GUDO_PANE_ID", parents), None);
    }

    #[test]
    fn the_daemon_boundary_is_checked_before_its_environment() {
        let parents = [ancestor(
            20,
            false,
            &["GUDO_DAEMON_PID=20", "GUDO_PANE_ID=private-parent-pane"],
        )];
        assert_eq!(inherited_variable("GUDO_PANE_ID", parents), None);
    }

    #[test]
    fn malformed_or_conflicting_host_markers_fail_closed() {
        for marker in ["0", "not-a-pid"] {
            let parents = [ancestor(
                30,
                false,
                &[
                    &format!("GUDO_DAEMON_PID={marker}"),
                    "GUDO_PANE_ID=private-pane",
                ],
            )];
            assert_eq!(inherited_variable("GUDO_PANE_ID", parents), None);
        }
        let parents = [
            ancestor(30, false, &["GUDO_DAEMON_PID=20"]),
            ancestor(
                25,
                false,
                &["GUDO_DAEMON_PID=10", "GUDO_PANE_ID=private-other-pane"],
            ),
        ];
        assert_eq!(inherited_variable("GUDO_PANE_ID", parents), None);
    }

    const PROBE_TEST_NAME: &str =
        "procinfo::ancestry::tests::cleared_helpers_stop_at_real_process_boundaries";

    fn isolate_command(command: &mut std::process::Command, role: &str) {
        command.args(["--exact", PROBE_TEST_NAME, "--nocapture"]);
        command.env_clear().env("GUDO_TEST_ANCESTRY_ROLE", role);
    }

    fn probe_command(executable: &std::path::Path) -> std::process::Command {
        let mut command = std::process::Command::new(executable);
        isolate_command(&mut command, "probe");
        command
    }

    fn host_command(executable: &std::path::Path) -> std::process::Command {
        let mut command = if executable
            .file_name()
            .is_some_and(|name| name == "private-renamed-host")
        {
            let mut command = std::process::Command::new("/bin/sh");
            command.args([
                "-c",
                &format!("export {}=$$; exec \"$@\"", brand::DAEMON_PID_ENV),
                "test-host",
            ]);
            command.arg(executable);
            command
        } else {
            std::process::Command::new(executable)
        };
        isolate_command(&mut command, "host");
        command
    }

    #[test]
    fn cleared_helpers_stop_at_real_process_boundaries() {
        match std::env::var("GUDO_TEST_ANCESTRY_ROLE").as_deref() {
            Ok("probe") => {
                assert!(std::env::var("GUDO_PANE_ID").is_err());
                assert_eq!(super::super::inherited_env_var("GUDO_PANE_ID"), None);
                return;
            }
            Ok("host") => {
                let output = probe_command(&std::env::current_exe().unwrap())
                    .output()
                    .unwrap();
                assert!(output.status.success(), "{output:?}");
                return;
            }
            _ => {}
        }
        let directory = tempfile::tempdir().unwrap();
        for name in [
            brand::RELEASE_DAEMON_BIN,
            brand::DEV_DAEMON_BIN,
            "private-renamed-host",
        ] {
            let executable = directory.path().join(name);
            std::fs::copy(std::env::current_exe().unwrap(), &executable).unwrap();
            let output = host_command(&executable)
                .env("HOME", directory.path())
                .env("GUDO_PANE_ID", "private-stale-parent")
                .output()
                .unwrap();
            assert!(output.status.success(), "{name}: {output:?}");
        }
    }

    #[test]
    fn the_agents_own_pane_is_available_below_its_daemon() {
        let parents = [
            ancestor(
                30,
                false,
                &["GUDO_DAEMON_PID=20", "GUDO_PANE_ID=private-agent-pane"],
            ),
            ancestor(20, true, &["GUDO_PANE_ID=private-parent-pane"]),
        ];
        assert_eq!(
            inherited_variable("GUDO_PANE_ID", parents).as_deref(),
            Some("private-agent-pane")
        );
    }
}
