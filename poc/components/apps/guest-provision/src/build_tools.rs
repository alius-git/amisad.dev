// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 429eb9a6-bf51-4f1e-b2d6-9d19caca7f0b

use crate::{child, Failure, Workspace};
use std::env;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::process::Command;

const RUSTUP: &str = "1.29.3";
const TOOLCHAIN: &str = "1.99.1";
const BAZELISK: &str = "v1.30.0";

struct Platform {
    rust_target: &'static str,
    rustup_digest: &'static str,
    bazel_arch: &'static str,
    bazelisk_digest: &'static str,
}

fn platform(architecture: &str) -> Result<Platform, Failure> {
    match architecture {
        "x86_64" => Ok(Platform {
            rust_target: "x86_64-unknown-linux-gnu",
            rustup_digest: "b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55",
            bazel_arch: "amd64",
            bazelisk_digest: "a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8",
        }),
        "aarch64" => Ok(Platform {
            rust_target: "aarch64-unknown-linux-gnu",
            rustup_digest: "9f608c142e0e38a78957d0661ba1dfaf0b6fb37184cfaa4b9a0aa57af6184282",
            bazel_arch: "arm64",
            bazelisk_digest: "b2bcc040c213b44586b121bda6d983c35df121b917c3a7a66fb16f2fa0df1a4f",
        }),
        _ => Err(Failure::new(
            1,
            "Unsupported native build-tool architecture",
        )),
    }
}

fn io_error(error: std::io::Error) -> Failure {
    Failure::new(1, error.to_string())
}

pub(super) fn text(path: &Path) -> Result<&str, Failure> {
    path.to_str()
        .ok_or_else(|| Failure::new(1, "Invalid build-tool file name"))
}

fn executable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0)
}

fn has_command(name: &str) -> bool {
    env::var_os("PATH")
        .is_some_and(|path| env::split_paths(&path).any(|dir| executable(&dir.join(name))))
}

pub(super) async fn run_command(command: &mut Command, label: &str) -> Result<(), Failure> {
    let status = command
        .kill_on_drop(true)
        .status()
        .await
        .map_err(io_error)?;
    if status.success() {
        return Ok(());
    }
    let exit = status
        .code()
        .and_then(|value| u8::try_from(value).ok())
        .unwrap_or(1);
    Err(Failure::new(exit, format!("{label} exited {exit}")))
}

async fn system(program: &str, args: &[&str]) -> Result<(), Failure> {
    run_command(Command::new(program).args(args), program).await
}

// Keep the framework's retry window and labels for complete attempts. A Rustup
// attempt includes download, verification, and execution, so a truncated
// transfer or failed initialization can both retry. The two download actions
// use functions to retain the existing per-attempt stall policy.
const RETRY: &str = r#"
if ! declare -F _yuruna_retry >/dev/null 2>&1 && [ -r /usr/local/lib/yuruna/yuruna-retry.sh ]; then
    . /usr/local/lib/yuruna/yuruna-retry.sh
fi
label=$1; shift
if ! declare -F _yuruna_retry >/dev/null 2>&1; then exec "$@"; fi
amisad_install_rustup() { "$@"; }
amisad_install_bazelisk() { "$@"; }
case "$label" in
    rustup_install) _yuruna_retry "$label" amisad_install_rustup "$@" ;;
    bazelisk_install) _yuruna_retry "$label" amisad_install_bazelisk "$@" ;;
    rust_toolchain) _yuruna_retry "$label" "$@" ;;
    *) exit 2 ;;
esac
"#;

async fn retry(label: &str, args: &[&str]) -> Result<(), Failure> {
    let mut command = Command::new("bash");
    command
        .args(["-c", RETRY, "amisad-build-retry", label])
        .args(args);
    if label == "bazelisk_install" {
        for (name, default) in [
            ("YURUNA_RETRY_WINDOW_SECONDS", "1800"),
            ("YURUNA_RETRY_MAX_DELAY_SECONDS", "120"),
        ] {
            let value = env::var_os(name)
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| default.into());
            command.env(name, value);
        }
    }
    run_command(&mut command, label).await
}

async fn verify(path: &Path, digest: &str, label: &str) -> Result<(), Failure> {
    let result = child("sha256sum", &[text(path)?], Duration::from_secs(30))
        .await
        .ok();
    let actual = result
        .as_ref()
        .and_then(|reading| std::str::from_utf8(&reading.stdout).ok())
        .and_then(|text| text.split_whitespace().next())
        .unwrap_or("<unreadable>");
    if actual == digest {
        println!("  integrity: sha256 verified ({label})");
        return Ok(());
    }
    let _ = fs::remove_file(path);
    Err(Failure::new(
        1,
        format!(
            "INTEGRITY MISMATCH -- refusing to use {label}\npinned:   {digest}\nactual:   {actual}"
        ),
    ))
}

async fn rustup_attempt(target: &Platform) -> Result<(), Failure> {
    let work = Workspace::create(&env::temp_dir(), "amisad-rustup").await?;
    let binary = work.0.join("rustup-init");
    let url = format!(
        "https://static.rust-lang.org/rustup/archive/{RUSTUP}/{}/rustup-init",
        target.rust_target
    );
    system(
        "curl",
        &[
            "--proto",
            "=https",
            "--tlsv1.2",
            "-fsSL",
            "--connect-timeout",
            "15",
            "--max-time",
            "600",
            "-o",
            text(&binary)?,
            &url,
        ],
    )
    .await?;
    verify(
        &binary,
        target.rustup_digest,
        &format!("rustup-init {RUSTUP} ({})", target.rust_target),
    )
    .await?;
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).map_err(io_error)?;
    system(text(&binary)?, &["-y", "--default-toolchain", TOOLCHAIN]).await
}

async fn bazelisk_attempt(target: &Platform, work: &Path) -> Result<(), Failure> {
    let binary = work.join("bazelisk");
    let url = format!(
        "https://github.com/bazelbuild/bazelisk/releases/download/{BAZELISK}/bazelisk-linux-{}",
        target.bazel_arch
    );
    system(
        "curl",
        &[
            "-fsSL",
            "--connect-timeout",
            "15",
            "--max-time",
            "300",
            "-o",
            text(&binary)?,
            &url,
        ],
    )
    .await?;
    verify(
        &binary,
        target.bazelisk_digest,
        &format!("bazelisk {BAZELISK} (linux-{})", target.bazel_arch),
    )
    .await
}

pub async fn setup() -> Result<(), Failure> {
    platform(env::consts::ARCH)?;
    for args in [
        &["apt-get", "update", "-y"][..],
        &[
            "apt-get",
            "install",
            "-y",
            "git",
            "curl",
            "build-essential",
            "pkg-config",
            "python3",
        ],
    ] {
        run_command(
            Command::new("sudo")
                .args(args)
                .env("DEBIAN_FRONTEND", "noninteractive"),
            "apt-get",
        )
        .await?;
    }
    let home = PathBuf::from(
        env::var_os("HOME")
            .ok_or_else(|| Failure::new(1, "The build account home is unavailable"))?,
    );
    let program = env::current_exe().map_err(io_error)?;
    if !has_command("rustup") && !executable(&home.join(".cargo/bin/rustup")) {
        retry(
            "rustup_install",
            &[text(&program)?, "build-tools-attempt", "rustup"],
        )
        .await?;
    }
    // Rustup writes the Cargo environment for this account. Keep its quoting
    // and other exports rather than interpreting that file in the provisioner.
    system(
        "bash",
        &[
            "-ec",
            ". \"$HOME/.cargo/env\"; exec \"$@\"",
            "amisad-build-env",
            text(&program)?,
            "build-tools-configure",
        ],
    )
    .await
}

pub async fn configure() -> Result<(), Failure> {
    let current = child("rustc", &["--version"], Duration::from_secs(5)).await;
    if !current.is_ok_and(|version| {
        String::from_utf8_lossy(&version.stdout).starts_with(&format!("rustc {TOOLCHAIN} "))
    }) {
        retry(
            "rust_toolchain",
            &[
                "rustup",
                "toolchain",
                "install",
                TOOLCHAIN,
                "--profile",
                "minimal",
            ],
        )
        .await?;
        system("rustup", &["default", TOOLCHAIN]).await?;
    }
    system("cargo", &["--version"]).await?;
    system("rustc", &["--version"]).await?;
    if !has_command("bazel") {
        let work = Workspace::create(&env::temp_dir(), "amisad-bazelisk").await?;
        let program = env::current_exe().map_err(io_error)?;
        retry(
            "bazelisk_install",
            &[
                text(&program)?,
                "build-tools-attempt",
                "bazelisk",
                text(&work.0)?,
            ],
        )
        .await?;
        system(
            "sudo",
            &[
                "install",
                "-m",
                "0755",
                text(&work.0.join("bazelisk"))?,
                "/usr/local/bin/bazel",
            ],
        )
        .await?;
    }
    for name in ["cargo", "rustc", "bazel", "git", "python3"] {
        if !has_command(name) {
            return Err(Failure::new(
                1,
                format!("tool not on PATH after install: {name}"),
            ));
        }
    }
    system("sync", &[]).await?;
    println!("AmisAd build tools installed");
    Ok(())
}

pub async fn attempt(args: &[String]) -> Result<(), Failure> {
    let target = platform(env::consts::ARCH)?;
    match args {
        [tool] if tool == "rustup" => rustup_attempt(&target).await,
        [tool, path] if tool == "bazelisk" => {
            let work = Path::new(path);
            let private = work.parent() == Some(&env::temp_dir())
                && work
                    .file_name()
                    .is_some_and(|name| name.to_string_lossy().starts_with("amisad-bazelisk."))
                && fs::symlink_metadata(work).is_ok_and(|entry| {
                    entry.is_dir()
                        && entry.mode() & 0o777 == 0o700
                        && entry.uid() == unsafe { libc::geteuid() }
                });
            if !private {
                return Err(Failure::new(
                    1,
                    "The Bazelisk download directory is not private",
                ));
            }
            bazelisk_attempt(&target, work).await
        }
        _ => Err(Failure::new(2, "Invalid build-tool attempt")),
    }
}
