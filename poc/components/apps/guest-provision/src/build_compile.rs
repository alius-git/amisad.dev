// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42fb6a31-845b-4221-b1b3-2aeed4548fd4

use crate::{
    build_tools::{run_command, text},
    core_deploy_seed::{check_pin, fetch_archive, verify_archive},
    runtime,
    scenarios::Endpoint,
    Failure, Workspace,
};
use std::{
    collections::VecDeque,
    env,
    fs::{self, File},
    io::{self, BufRead, BufReader},
    path::Path,
    process::Stdio,
    time::Duration,
};
use tokio::{process::Command, time::sleep};

const STASH_CAP: u64 = 100 * 1024 * 1024;
const SCP_ATTEMPTS: u8 = 3;

fn io_error(error: io::Error) -> Failure {
    Failure::new(1, error.to_string())
}

async fn replace_project(source: &Path, pin: &str, project: &Path) -> Result<(), Failure> {
    verify_archive(source, pin).await?;
    match project.symlink_metadata() {
        Ok(entry) if entry.is_dir() => fs::remove_dir_all(project).map_err(io_error)?,
        Ok(_) => fs::remove_file(project).map_err(io_error)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(io_error(error)),
    }
    fs::create_dir(project).map_err(io_error)?;
    run_command(
        Command::new("tar").args(["-xzf", text(source)?, "-C", text(project)?]),
        "project extraction",
    )
    .await?;
    fs::remove_file(source).map_err(io_error)
}

struct Build<'a> {
    poc: &'a Path,
    destination: &'a Path,
    commands: Option<&'a Path>,
    upload_backoff: Duration,
}

impl Build<'_> {
    fn command(&self, program: &str) -> Command {
        let mut command = match self.commands {
            Some(path) => Command::new(path.join(program)),
            None => Command::new(program),
        };
        command.current_dir(self.poc);
        command
    }

    async fn execute(&self, program: &str, arguments: &[&str]) -> Result<(), Failure> {
        run_command(self.command(program).args(arguments), program).await
    }

    async fn check_stash(&self, host: &str) -> Result<(), Failure> {
        if host.is_empty() {
            return Err(Failure::new(
                3,
                "STASH_HOST is empty - cannot upload binaries; aborting before build.",
            ));
        }
        let endpoint = Endpoint::parse(&format!("http://{host}"))
            .map_err(|_| Failure::new(3, "STASH_HOST is not a reachable host and port"))?;
        let probe = format!("{}/healthz", endpoint.url());
        let checked = run_command(
            self.command("curl")
                .args(["-fsS", "--noproxy", "*", "--connect-timeout", "20", &probe])
                .stdout(Stdio::null()),
            "stash health check",
        )
        .await;
        checked.map_err(|_| {
            Failure::new(
                3,
                format!(
                    "STASH UNREACHABLE at {} - cannot upload binaries; aborting before build.",
                    endpoint.url()
                ),
            )
        })
    }

    async fn bazel_gate(&self, work: &Path) -> Result<(), Failure> {
        let log = work.join("bazel-gate.log");
        let capture = File::create(&log).map_err(io_error)?;
        let packages = run_command(
            self.command("sudo")
                .args(["apt-get", "install", "-y", "ca-certificates-java"])
                .stdout(Stdio::null())
                .stderr(Stdio::null()),
            "Bazel CA package",
        )
        .await;
        let passed = if packages.is_ok() {
            run_command(
                self.command("bazel")
                    .args([
                        "--host_jvm_args=-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts",
                        "build",
                        "//...",
                    ])
                    .stdout(Stdio::from(capture.try_clone().map_err(io_error)?))
                    .stderr(Stdio::from(capture)),
                "Bazel gate",
            )
            .await
            .is_ok()
        } else {
            false
        };
        let final_log = self.destination.join("bazel-gate.log");
        fs::rename(log, &final_log).map_err(io_error)?;
        if passed {
            println!("bazel gate: PASS");
            return Ok(());
        }
        let (registry_tls, tail) = bazel_error(&final_log).map_err(io_error)?;
        if registry_tls {
            println!("WARNING: bazel gate skipped (registry TLS trust); using cargo build");
            return Ok(());
        }
        eprintln!("bazel gate FAILED for a non-TLS reason; last 40 lines:");
        for line in tail {
            eprintln!("{line}");
        }
        Err(Failure::new(5, "Bazel gate failed"))
    }

    async fn pack(&self, work: &Path, label: &str) -> Result<(), Failure> {
        let staged = work.join(label);
        let mut arguments = vec!["czf", text(&staged)?, "-C", "target/release"];
        for binary in runtime::binaries() {
            arguments.push(binary);
        }
        self.execute("tar", &arguments).await?;
        let size = staged.symlink_metadata().map_err(io_error)?.len();
        if size >= STASH_CAP {
            return Err(Failure::new(4, format!("binaries tarball {size}B exceeds the stash 100MB per-file cap; strip binaries or split.")));
        }
        let target = self.destination.join(label);
        // The following digest step reads the established name only after a
        // successful upload. Replace that name with complete archive bytes.
        fs::rename(staged, &target).map_err(io_error)?;
        self.execute("ls", &["-l", text(&target)?]).await
    }

    async fn upload(&self, work: &Path, host: &str, label: &str) -> Result<(), Failure> {
        let source = self.destination.join(label);
        let remote = format!("amisad-poc@{host}:/amisad/{label}");
        let scratch = work.join("scp-upload.log");
        for attempt in 1..=SCP_ATTEMPTS {
            println!(
                "scp upload attempt {attempt}/{SCP_ATTEMPTS}: {} -> amisad-poc@{host}",
                source.display()
            );
            let error = File::create(&scratch).map_err(io_error)?;
            let sent = run_command(
                self.command("scp")
                    .args([
                        "-O",
                        "-o",
                        "StrictHostKeyChecking=no",
                        "-o",
                        "UserKnownHostsFile=/dev/null",
                        "-o",
                        "GlobalKnownHostsFile=/dev/null",
                        "-o",
                        "ConnectTimeout=20",
                        text(&source)?,
                        &remote,
                    ])
                    .stderr(Stdio::from(error)),
                "scp",
            )
            .await;
            let final_log = self.destination.join("scp-upload.log");
            fs::rename(&scratch, &final_log).map_err(io_error)?;
            match sent {
                Ok(()) => {
                    println!("uploaded {label} to stash {host} (label amisad-poc)");
                    return Ok(());
                }
                Err(failure) => {
                    eprintln!(
                        "scp upload attempt {attempt}/{SCP_ATTEMPTS} failed (rc={}); scp reported:",
                        failure.exit
                    );
                    let diagnostics = BufReader::new(File::open(&final_log).map_err(io_error)?);
                    for line in diagnostics.split(b'\n') {
                        let line = line.map_err(io_error)?;
                        eprintln!("    {}", String::from_utf8_lossy(&line));
                    }
                }
            }
            if attempt < SCP_ATTEMPTS {
                println!("scp upload: retrying in {}s", self.upload_backoff.as_secs());
                sleep(self.upload_backoff).await;
            }
        }
        Err(Failure::new(6, format!("scp upload failed after {SCP_ATTEMPTS} attempts; the binaries never reached stash {host} and amisad-core has nothing to deploy.")))
    }

    async fn compile(&self, host: &str) -> Result<(), Failure> {
        println!("== stash reachability (fail fast, before the build) ==");
        self.check_stash(host).await?;
        let work = Workspace::create(self.destination, "amisad-build").await?;
        println!("== build (bazel gate; cargo fallback ONLY on registry TLS trust) ==");
        self.bazel_gate(&work.0).await?;
        println!("== test + release build ==");
        self.execute("cargo", &["test", "--workspace"]).await?;
        self.execute("cargo", &["build", "--release", "--workspace"])
            .await?;
        let label = format!("amisad-{}-binaries.tgz", env::consts::ARCH);
        println!("== pack binaries ==");
        self.pack(&work.0, &label).await?;
        println!("== upload binaries to the stash service ==");
        self.upload(&work.0, host, &label).await?;
        println!("amisad-build COMPILE+UPLOAD PASSED");
        Ok(())
    }
}

fn bazel_error(path: &Path) -> io::Result<(bool, VecDeque<String>)> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut line = Vec::new();
    let mut tail = VecDeque::with_capacity(40);
    let mut tls = false;
    while reader.read_until(b'\n', &mut line)? != 0 {
        let text = String::from_utf8_lossy(&line);
        tls |= ["PKIX", "trustAnchors", "SSLHandshake"]
            .iter()
            .any(|pattern| text.contains(pattern));
        if tail.len() == 40 {
            tail.pop_front();
        }
        tail.push_back(text.trim_end_matches('\n').to_owned());
        line.clear();
    }
    Ok((tls, tail))
}

pub(super) async fn run(home: &Path) -> Result<(), Failure> {
    if !home.is_absolute() || !home.is_dir() {
        return Err(Failure::new(7, "The build account home is unavailable."));
    }
    let pin = env::var("AMISAD_PROJECT_ARCHIVE_SHA256").unwrap_or_default();
    let override_unverified = env::var("AMISAD_ALLOW_UNVERIFIED").as_deref() == Ok("1");
    check_pin(&pin, override_unverified)?;
    let downloads = Workspace::create(&env::temp_dir(), "amisad-fetch").await?;
    let archive = downloads.0.join("project-poc.tar.gz");
    let project = home.join("amisad.dev");
    println!("== obtain project tree (lab: host-served tarball of amisad.dev HEAD) ==");
    fetch_archive(&archive).await?;
    replace_project(&archive, &pin, &project).await?;
    let host = env::var("STASH_HOST").unwrap_or_default();
    Build {
        poc: &project.join("poc"),
        destination: Path::new("/tmp"),
        commands: None,
        upload_backoff: Duration::from_secs(5),
    }
    .compile(&host)
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture {
        workspace: Workspace,
    }

    impl Fixture {
        async fn new() -> Self {
            let workspace = Workspace::create(&env::temp_dir(), "amisad-build-compile-test")
                .await
                .unwrap();
            for name in ["poc/target/release", "out", "bin"] {
                fs::create_dir_all(workspace.0.join(name)).unwrap();
            }
            for binary in runtime::binaries() {
                fs::write(workspace.0.join("poc/target/release").join(binary), binary).unwrap();
            }
            let commands = r#"#!/bin/bash
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> calls
case "$tool" in
    curl) [ ! -f unavailable ] ;;
    bazel)
        if [ -f tls ]; then echo 'SSLHandshake: registry trust' >&2; exit 1; fi
        if [ -f bad_module ]; then echo 'MODULE.bazel is not valid' >&2; exit 1; fi ;;
    tar)
        if [ -f oversized ]; then exec truncate -s 104857600 "$2"; fi
        exec /usr/bin/tar "$@" ;;
    ls) exec /usr/bin/ls "$@" ;;
    scp)
        [ "$#" = 11 ] && [ "$1" = -O ] && [ -f "${10}" ] || exit 81
        if [ -f refuse_upload ]; then echo 'connection refused' >&2; exit 1; fi
        if [ -f retry_upload ]; then rm retry_upload; echo 'temporary connection loss' >&2; exit 1; fi
        cp -- "${10}" uploaded.tgz ;;
esac
"#;
            for name in ["curl", "sudo", "bazel", "cargo", "tar", "ls", "scp"] {
                let path = workspace.0.join("bin").join(name);
                fs::write(&path, commands).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
            }
            Self { workspace }
        }

        fn marker(&self, name: &str) {
            fs::write(self.workspace.0.join("poc").join(name), "").unwrap();
        }

        async fn compile(&self, host: &str) -> Result<(), Failure> {
            Build {
                poc: &self.workspace.0.join("poc"),
                destination: &self.workspace.0.join("out"),
                commands: Some(&self.workspace.0.join("bin")),
                upload_backoff: Duration::ZERO,
            }
            .compile(host)
            .await
        }

        fn calls(&self) -> String {
            fs::read_to_string(self.workspace.0.join("poc/calls")).unwrap_or_default()
        }

        fn archive(&self) -> std::path::PathBuf {
            self.workspace
                .0
                .join("out")
                .join(format!("amisad-{}-binaries.tgz", env::consts::ARCH))
        }
    }

    #[tokio::test]
    async fn publishes_the_same_ordered_archive_that_the_caller_can_hash() {
        let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
        let work = Fixture::new().await;
        work.marker("tls");
        work.marker("retry_upload");
        work.compile("stash.fixture").await.unwrap();
        let calls = work.calls();
        let label = work
            .archive()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert!(calls.starts_with("curl -fsS --noproxy * --connect-timeout 20 http://stash.fixture/healthz\nsudo apt-get install -y ca-certificates-java\nbazel --host_jvm_args=-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts build //...\ncargo test --workspace\ncargo build --release --workspace\n"), "{calls}");
        assert_eq!(
            calls
                .matches(&format!("amisad-poc@stash.fixture:/amisad/{label}"))
                .count(),
            2
        );
        assert!(calls.contains("scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=20 "));
        let listings = std::process::Command::new("tar")
            .args(["tzf", text(&work.archive()).unwrap()])
            .output()
            .unwrap();
        assert!(listings.status.success());
        assert_eq!(
            String::from_utf8(listings.stdout)
                .unwrap()
                .lines()
                .collect::<Vec<_>>(),
            runtime::binaries().collect::<Vec<_>>()
        );
        assert_eq!(
            fs::read(work.archive()).unwrap(),
            fs::read(work.workspace.0.join("poc/uploaded.tgz")).unwrap()
        );
    }

    #[tokio::test]
    async fn refuses_broken_preconditions_without_publishing_an_archive() {
        let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
        for (marker, code, cargo, transfers) in [
            ("unavailable", 3, false, 0),
            ("bad_module", 5, false, 0),
            ("oversized", 4, true, 0),
            ("refuse_upload", 6, true, 3),
        ] {
            let work = Fixture::new().await;
            work.marker(marker);
            assert_eq!(work.compile("stash.fixture").await.unwrap_err().exit, code);
            let calls = work.calls();
            assert_eq!(calls.contains("cargo test --workspace"), cargo, "{calls}");
            assert_eq!(
                calls
                    .lines()
                    .filter(|line| line.starts_with("scp "))
                    .count(),
                transfers
            );
            assert!(!work.workspace.0.join("poc/uploaded.tgz").exists());
            if transfers == 0 {
                assert!(!work.archive().exists());
            }
        }
    }

    #[tokio::test]
    async fn refuses_the_wrong_source_archive_before_replacing_the_project_tree() {
        let work = Workspace::create(&env::temp_dir(), "amisad-compile-pin-test")
            .await
            .unwrap();
        let project = work.0.join("existing");
        let archive = work.0.join("source.tar.gz");
        fs::create_dir(&project).unwrap();
        fs::write(project.join("previous"), "the existing checkout").unwrap();
        fs::write(&archive, "unverified bytes").unwrap();
        let failure = replace_project(&archive, &"a".repeat(64), &project)
            .await
            .unwrap_err();
        assert_eq!(failure.exit, 7);
        assert!(failure.detail.contains("INTEGRITY MISMATCH"));
        assert_eq!(
            fs::read_to_string(project.join("previous")).unwrap(),
            "the existing checkout"
        );
    }
}
