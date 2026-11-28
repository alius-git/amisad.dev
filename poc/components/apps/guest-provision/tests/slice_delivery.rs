// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42ad9cc2-fa32-4982-b780-7151ab803780

#![cfg(target_os = "linux")]

use std::{
    env, fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Output},
};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        let output = Command::new("mktemp")
            .args(["-d", "-t", "amisad-slice-delivery.XXXXXXXX"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let path = PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
        let fixture = Self(path);
        fixture.tool("ssh", r#"#!/bin/bash
case "${@: -1}" in
    'cat '*)
        echo 'discover' >> "$TRACE"
        if [ "$MODE" = legacy ]; then printf '%s\n' 'ExecStart=/opt/legacy edge-report'
        else printf '%s\n' 'ExecStart="/usr/local/lib/yuruna/amisad-artifacts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/amisad-provision" edge-report'
        fi
        ;;
    *' --help') echo 'slice-stop slice-start'; echo 'capabilities' >> "$TRACE" ;;
    *' slice-stop') echo 'stop' >> "$TRACE"; echo 'previous slice stopped' ;;
    *' slice-start '*)
        echo 'start' >> "$TRACE"
        ( eval "set -- ${*: -1}"; test "${4}" = "region's name" ) || exit 9
        if [[ "$*" == *fixture-token* ]]; then exit 10; fi
        IFS= read -r secret
        [ "$secret" = 'fixture-token' ] || exit 11
        ;;
    'hostname -I') echo 'address' >> "$TRACE"; echo '192.0.2.5 192.0.2.6' ;;
    *) exit 12 ;;
esac
"#);
        fixture.tool(
            "scp",
            r#"#!/bin/bash
echo 'copy' >> "$TRACE"
[ "${@: -1}" = 'operator@edge.test:/tmp/slice-runtime' ] || exit 9
[ "$MODE" != copy-failed ] || exit 2
"#,
        );
        fixture.tool(
            "kubectl",
            r#"#!/bin/bash
echo 'secret' >> "$TRACE"
printf 'Zml4dHVyZS10b2tlbg=='
"#,
        );
        fixture
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn tool(&self, name: &str, script: &str) {
        let path = self.path().join(name);
        fs::write(&path, script).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }

    fn deliver(&self, mode: &str) -> Output {
        self.call(
            mode,
            "slice-deliver",
            "operator@edge.test",
            "report-address",
        )
    }

    fn call(&self, mode: &str, operation: &str, target: &str, flag: &str) -> Output {
        let path = env::join_paths(
            std::iter::once(self.path().to_owned())
                .chain(env::split_paths(&env::var_os("PATH").unwrap())),
        )
        .unwrap();
        Command::new(env!("CARGO_BIN_EXE_amisad-provision"))
            .args([
                operation,
                target,
                "region's name",
                "http://example.test:5000",
                "http://example.test:5001",
                flag,
            ])
            .env("PATH", path)
            .env("REAL_HOME", self.path())
            .env("TRACE", self.path().join("trace"))
            .env("MODE", mode)
            .output()
            .unwrap()
    }

    fn trace(&self) -> String {
        fs::read_to_string(self.path().join("trace")).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(self.path());
    }
}

#[test]
fn transfers_after_stop_and_sends_the_token_only_through_standard_input() {
    let fixture = Fixture::new();
    let output = fixture.deliver("enrolled");
    assert!(
        output.status.success(),
        "{:?}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fixture.trace(),
        "discover\ncapabilities\nstop\ncopy\nsecret\nstart\naddress\n"
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(
        stdout,
        "previous slice stopped\nedge-started\nAMISAD_SLICE_ADDRESS=192.0.2.5\n"
    );
}

#[test]
fn chooses_legacy_only_before_any_edge_effect() {
    let legacy = Fixture::new();
    assert_eq!(legacy.deliver("legacy").status.code(), Some(2));
    assert_eq!(legacy.trace(), "discover\n");
    let failed = Fixture::new();
    assert_eq!(failed.deliver("copy-failed").status.code(), Some(1));
    assert_eq!(failed.trace(), "discover\ncapabilities\nstop\ncopy\n");
}

#[test]
fn scenario_refuses_an_unconfigured_single_vm_and_does_not_replay_a_transfer_failure() {
    let missing_edge = Fixture::new();
    let refused = missing_edge.call("enrolled", "slice-scenario-start", "", "0");
    assert_eq!(refused.status.code(), Some(4));
    assert!(!missing_edge.path().join("trace").exists());

    let legacy = Fixture::new();
    let fallback = legacy.call("legacy", "slice-scenario-start", "operator@edge.test", "0");
    assert_eq!(fallback.status.code(), Some(2));
    assert_eq!(legacy.trace(), "discover\n");

    let interrupted = Fixture::new();
    let failed = interrupted.call(
        "copy-failed",
        "slice-scenario-start",
        "operator@edge.test",
        "0",
    );
    assert_eq!(failed.status.code(), Some(1));
    assert_eq!(interrupted.trace(), "discover\ncapabilities\nstop\ncopy\n");
}
