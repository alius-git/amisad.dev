// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42f2aa61-526e-409c-8d9c-9e37c766cc7e

#![cfg(target_os = "linux")]

use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf, process::Command, sync::Mutex};

static FIXTURES: Mutex<()> = Mutex::new(());

struct Fixture(PathBuf);

const TOOL_ENTRY: &str =
    include_str!("../../../../test/ubuntu.server.24/ubuntu.server.24.amisad-build.tools.sh");

impl Fixture {
    fn new(with_rustup: bool, with_bazel: bool) -> Self {
        let result = Command::new("mktemp")
            .args(["-dt", "amisad-build-tools.XXXXXXXX"])
            .output()
            .unwrap();
        assert!(result.status.success());
        let root = PathBuf::from(String::from_utf8(result.stdout).unwrap().trim());
        for path in [
            "bin",
            "account/.cargo",
            "work",
            "etc",
            "lib/amisad-artifacts",
        ] {
            fs::create_dir_all(root.join(path)).unwrap();
        }
        fs::write(root.join("etc/amisad-artifacts.json"), "{}\n").unwrap();
        let candidate = root.join("lib/amisad-artifacts").join("a".repeat(64));
        fs::create_dir(&candidate).unwrap();
        fs::copy(
            env!("CARGO_BIN_EXE_amisad-provision"),
            candidate.join("amisad-provision"),
        )
        .unwrap();
        let entry = TOOL_ENTRY
            .replace("/etc/yuruna", root.join("etc").to_str().unwrap())
            .replace("/usr/local/lib/yuruna", root.join("lib").to_str().unwrap());
        fs::write(root.join("build-tools.sh"), entry).unwrap();
        fs::write(
            root.join("account/.cargo/env"),
            "export AMISAD_FIXTURE_CARGO_ENV=loaded\n",
        )
        .unwrap();
        for (name, path) in [
            ("bash", "/bin/bash"),
            ("mktemp", "/usr/bin/mktemp"),
            ("sha256sum", "/usr/bin/sha256sum"),
        ] {
            std::os::unix::fs::symlink(path, root.join("bin").join(name)).unwrap();
        }
        let commands = r#"#!/bin/bash
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$TRACE"
case "$tool" in
    sudo)
        case "$1" in
            */install-rust-artifacts)
                [ "$2" = --plan-file ] && [ -f "$3" ] && [ "$5 $6" = 'amisad-provision framework-revision' ] || exit 84
                printf '%s\n' "$4/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
            apt-get) [ "${DEBIAN_FRONTEND:-}" = noninteractive ] ;;
            *) exit 84 ;;
        esac ;;
    rustup)
        [ "${AMISAD_FIXTURE_CARGO_ENV:-}" = loaded ] || exit 84
        if [ "$1" = default ]; then : > selected; fi ;;
    rustc)
        [ "${AMISAD_FIXTURE_CARGO_ENV:-}" = loaded ] || exit 84
        if [ -f selected ]; then echo 'rustc 1.99.1 (fixture)'; else echo 'rustc 1.96.1 (fixture)'; fi ;;
    cargo) echo 'cargo 1.99.1 (fixture)' ;;
    curl)
        while [ "$#" -gt 0 ]; do
            if [ "$1" = -o ]; then destination=$2; shift; fi
            shift
        done
        printf '#!/bin/sh\necho unexpectedly-ran >> "$TRACE"\n' > "$destination" ;;
esac
"#;
        for tool in [
            "sudo", "rustup", "rustc", "cargo", "bazel", "git", "python3", "sync", "curl",
        ] {
            if (tool == "rustup" && !with_rustup) || (tool == "bazel" && !with_bazel) {
                continue;
            }
            let location = root.join("bin").join(tool);
            fs::write(&location, commands).unwrap();
            fs::set_permissions(location, fs::Permissions::from_mode(0o700)).unwrap();
        }
        Self(root)
    }

    fn run(&self) -> std::process::Output {
        Command::new("/bin/bash")
            .args(["-ec", r#"
_yuruna_retry() {
    printf 'retry %s %s %s\n' "$1" "${YURUNA_RETRY_WINDOW_SECONDS:-}" "${YURUNA_RETRY_MAX_DELAY_SECONDS:-}" >> "$TRACE"
    shift
    "$@" || "$@"
}
export -f _yuruna_retry
exec "$@"
"#, "fixture-build-tools", "/bin/bash", "build-tools.sh"])
            .current_dir(&self.0)
            .env_clear()
            .env("PATH", self.0.join("bin"))
            .env("HOME", self.0.join("account"))
            .env("TMPDIR", self.0.join("work"))
            .env("TRACE", self.0.join("trace"))
            .output()
            .unwrap()
    }

    fn trace(&self) -> String {
        fs::read_to_string(self.0.join("trace")).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn selects_the_pinned_toolchain_before_final_build_guest_validation() {
    let _fixture = FIXTURES.lock().unwrap();
    let fixture = Fixture::new(true, true);
    let result = fixture.run();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(String::from_utf8_lossy(&result.stdout).contains("AmisAd build tools installed"));
    let trace = fixture.trace();
    let (verification, commands) = trace.split_once('\n').unwrap();
    assert!(verification.ends_with("amisad-provision framework-revision"));
    assert_eq!(commands, "sudo apt-get update -y\nsudo apt-get install -y git curl build-essential pkg-config python3\nrustc --version\nretry rust_toolchain  \nrustup toolchain install 1.99.1 --profile minimal\nrustup default 1.99.1\ncargo --version\nrustc --version\nsync \n");
}

#[test]
fn corrupt_rustup_and_bazelisk_are_removed_and_never_run_or_installed() {
    let _fixture = FIXTURES.lock().unwrap();
    for rustup in [false, true] {
        let fixture = Fixture::new(rustup, false);
        let result = fixture.run();
        assert_eq!(result.status.code(), Some(1));
        let errors = String::from_utf8_lossy(&result.stderr);
        let trace = fixture.trace();
        assert_eq!(errors.matches("INTEGRITY MISMATCH").count(), 2, "{errors}");
        let (retry, uri) = if rustup {
            (
                "retry bazelisk_install 1800 120",
                "bazelisk/releases/download/v1.30.0/bazelisk-linux-",
            )
        } else {
            ("retry rustup_install  ", "rustup/archive/1.29.3/")
        };
        assert!(trace.contains(retry));
        assert_eq!(trace.matches(uri).count(), 2, "{trace}");
        assert!(
            !trace.contains("unexpectedly-ran")
                && !trace.contains("sudo install -m")
                && !trace.contains("sync ")
        );
        assert_eq!(fs::read_dir(fixture.0.join("work")).unwrap().count(), 0);
    }
}
