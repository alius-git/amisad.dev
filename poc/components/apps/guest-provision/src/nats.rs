// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 4208cff9-994f-4734-ac26-b93e4bdfdac5

use crate::{child, Failure, Workspace};
use std::fs;
use std::path::Path;
use std::process::Output;
use std::time::Duration;
use tokio::time::sleep;

const VERSION_PROBE: Duration = Duration::from_secs(5);
const SYSTEM_COMMAND: Duration = Duration::from_secs(30);
const YURUNA_GUEST: &str = "/usr/local/lib/yuruna/yuruna-guest";

// This unit is also installed by the standalone baseline script. Matching its
// bytes avoids restarting JetStream when an enrolled guest changes entrypoint.
const UNIT: &str = "# --- REGION: [Unit]
[Unit]
Description=NATS JetStream (AmisAd POC)
After=network-online.target

# --- REGION: [Service]
[Service]
ExecStart=/usr/local/bin/nats-server -js -m 8222
Restart=always
RestartSec=2

# --- REGION: [Install]
[Install]
WantedBy=multi-user.target
";

pub async fn run(version: &str, digest: &str) -> Result<(), Failure> {
    let release = Release::new(version, digest, std::env::consts::ARCH)?;
    let guest = Guest {
        executable: Path::new("/usr/local/bin/nats-server"),
        unit: Path::new("/etc/systemd/system/nats.service"),
        temp: &std::env::temp_dir(),
        commands: None,
        readiness_delay: Duration::from_secs(2),
    };
    guest.install(&release).await
}

struct Release<'a> {
    version: &'a str,
    digest: &'a str,
    asset: String,
}

impl<'a> Release<'a> {
    fn new(version: &'a str, digest: &'a str, architecture: &str) -> Result<Self, Failure> {
        let semver = version.strip_prefix('v').filter(|value| value.len() <= 30);
        let valid = semver.is_some_and(|value| {
            value.split('.').count() == 3
                && value
                    .split('.')
                    .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
        });
        if !valid
            || digest.len() != 64
            || !digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err(Failure::new(7, "Invalid pinned NATS release or SHA-256"));
        }
        let architecture = match architecture {
            "x86_64" => "amd64",
            "aarch64" => "arm64",
            _ => return Err(Failure::new(1, "Unsupported native NATS architecture")),
        };
        Ok(Self {
            version,
            digest,
            asset: format!("nats-server-{version}-linux-{architecture}"),
        })
    }

    fn binary_version(&self, bytes: &[u8]) -> bool {
        std::str::from_utf8(bytes).is_ok_and(|value| {
            value.trim_end_matches('\n') == format!("nats-server: {}", self.version)
        })
    }

    fn live_version(&self, bytes: &[u8]) -> bool {
        serde_json::from_slice::<serde_json::Value>(bytes)
            .is_ok_and(|value| value["version"].as_str() == self.version.strip_prefix('v'))
    }
}

struct Guest<'a> {
    executable: &'a Path,
    unit: &'a Path,
    temp: &'a Path,
    commands: Option<&'a Path>,
    readiness_delay: Duration,
}

impl Guest<'_> {
    async fn command(
        &self,
        program: &str,
        argv: &[&str],
        budget: Duration,
    ) -> Result<Output, Failure> {
        if let Some(path) = self.commands {
            let path = path.join(program);
            child(text(&path)?, argv, budget).await
        } else {
            child(program, argv, budget).await
        }
    }

    async fn install(&self, release: &Release<'_>) -> Result<(), Failure> {
        let executable = text(self.executable)?;
        let version = child(executable, &["--version"], VERSION_PROBE).await;
        let upgrade = !version.is_ok_and(|value| release.binary_version(&value.stdout));
        let unit_changed = fs::read(self.unit).map_or(true, |existing| existing != UNIT.as_bytes());
        if upgrade || unit_changed {
            let work = Workspace::create(self.temp, "amisad-nats").await?;
            if upgrade {
                self.install_binary(release, &work.0).await?;
            }
            if unit_changed {
                let unit = work.0.join("nats.service");
                fs::write(&unit, UNIT).map_err(|error| Failure::new(1, error.to_string()))?;
                self.command(
                    "sudo",
                    &["install", "-m", "0644", text(&unit)?, text(self.unit)?],
                    SYSTEM_COMMAND,
                )
                .await?;
                self.systemctl(&["daemon-reload"]).await?;
            }
        }
        self.systemctl(&["enable", "nats"]).await?;
        let action = if upgrade || unit_changed {
            "restart"
        } else {
            "start"
        };
        self.systemctl(&[action, "nats"]).await?;
        for _ in 0..30 {
            if self.healthy(release).await {
                self.command("sync", &[], SYSTEM_COMMAND).await?;
                println!("NATS JetStream deployed");
                return Ok(());
            }
            sleep(self.readiness_delay).await;
        }
        if let Ok(details) = self.systemctl(&["status", "nats", "--no-pager"]).await {
            eprintln!(
                "{}",
                String::from_utf8_lossy(&details.stdout)
                    .lines()
                    .rev()
                    .take(10)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .collect::<Vec<_>>()
                    .join("\n")
            );
        }
        Err(Failure::new(1, "NATS failed to become healthy"))
    }

    async fn install_binary(&self, release: &Release<'_>, work: &Path) -> Result<(), Failure> {
        let archive = work.join("nats-server.tar.gz");
        let archive_path = text(&archive)?;
        let url = format!(
            "https://github.com/nats-io/nats-server/releases/download/{}/{}.tar.gz",
            release.version, release.asset
        );
        if self.commands.is_none()
            && fs::symlink_metadata(YURUNA_GUEST).is_ok_and(|entry| entry.is_file())
        {
            // Reuse the guest's release retry policy, including refreshing
            // proxy trust and distinguishing permanent HTTP failures.
            child(
                YURUNA_GUEST,
                &["guest-retry", "wget", "wget", "-qO", archive_path, &url],
                Duration::from_secs(1900),
            )
            .await?;
        } else {
            self.command(
                "wget",
                &[
                    "--tries=3",
                    "--waitretry=5",
                    "--retry-connrefused",
                    "--read-timeout=60",
                    "-qO",
                    archive_path,
                    &url,
                ],
                Duration::from_secs(240),
            )
            .await?;
        }
        let hash = self
            .command("sha256sum", &[archive_path], SYSTEM_COMMAND)
            .await
            .ok();
        let checksum = hash
            .as_ref()
            .map_or_else(|| "".into(), |hash| String::from_utf8_lossy(&hash.stdout));
        let actual = checksum.split_whitespace().next().unwrap_or("<unreadable>");
        if actual != release.digest {
            return Err(Failure::new(
                7,
                format!(
                    "INTEGRITY MISMATCH: refusing NATS {} (pinned {}, actual {})",
                    release.version, release.digest, actual
                ),
            ));
        }
        println!(
            "  integrity: sha256 verified (the NATS server {})",
            release.version
        );
        let member = format!("{}/nats-server", release.asset);
        self.command(
            "tar",
            &["-xzf", archive_path, "-C", text(work)?, "--", &member],
            SYSTEM_COMMAND,
        )
        .await?;
        let server = work.join(&member);
        if !fs::symlink_metadata(&server).is_ok_and(|entry| entry.is_file()) {
            return Err(Failure::new(
                1,
                "The verified NATS release is missing its executable",
            ));
        }
        let result = child(text(&server)?, &["--version"], VERSION_PROBE).await?;
        if !release.binary_version(&result.stdout) {
            return Err(Failure::new(
                1,
                "The NATS release executable returned a different version",
            ));
        }
        self.command(
            "sudo",
            &[
                "install",
                "-m",
                "0755",
                text(&server)?,
                text(self.executable)?,
            ],
            SYSTEM_COMMAND,
        )
        .await?;
        Ok(())
    }

    async fn healthy(&self, release: &Release<'_>) -> bool {
        let probe = [
            "--silent",
            "--fail",
            "--connect-timeout",
            "2",
            "--max-time",
            "4",
            "--max-filesize",
            "65536",
        ];
        let curl = |url| {
            let mut args = probe.to_vec();
            args.push(url);
            args
        };
        if self
            .command(
                "curl",
                &curl("http://localhost:8222/healthz"),
                VERSION_PROBE,
            )
            .await
            .is_err()
        {
            return false;
        }
        self.command("curl", &curl("http://localhost:8222/varz"), VERSION_PROBE)
            .await
            .is_ok_and(|result| release.live_version(&result.stdout))
    }

    async fn systemctl(&self, arguments: &[&str]) -> Result<Output, Failure> {
        let mut argv = vec!["systemctl"];
        argv.extend_from_slice(arguments);
        self.command("sudo", &argv, SYSTEM_COMMAND).await
    }
}

fn text(path: &Path) -> Result<&str, Failure> {
    path.to_str()
        .ok_or_else(|| Failure::new(1, "Invalid NATS installation path"))
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    struct Fixture {
        root: Workspace,
        commands: PathBuf,
        executable: PathBuf,
        unit: PathBuf,
        trace: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let directory = std::process::Command::new("mktemp")
                .arg("-d")
                .output()
                .unwrap();
            assert!(directory.status.success());
            let root = PathBuf::from(std::str::from_utf8(&directory.stdout).unwrap().trim());
            let commands = root.join("bin");
            fs::create_dir(&commands).unwrap();
            let executable = root.join("system-nats-server");
            let unit = root.join("nats.service");
            fs::write(root.join("release"), b"pinned fixture tarball").unwrap();
            let fixture = Self {
                trace: root.join("commands"),
                executable,
                unit,
                commands,
                root: Workspace(root),
            };
            fixture.command("sha256sum", "exec sha256sum \"$@\"");
            fixture.command("sync", "echo sync >> \"$base/commands\"");
            fixture.command(
                "wget",
                r#"
echo wget >> "$base/commands"
while [ "$1" != -qO ]; do shift; done
cp -- "$base/release" "$2"
"#,
            );
            fixture.command(
                "tar",
                r#"
echo tar >> "$base/commands"
[ "$1" = -xzf ] && [ "$3" = -C ] && [ "$5" = -- ] || exit 8
out="$4/$6"
mkdir -p "$(dirname "$out")"
printf '%s\n' '#!/bin/sh' 'echo "nats-server: v2.15.1"' > "$out"
chmod 755 "$out"
"#,
            );
            fixture.command(
                "sudo",
                r#"
echo "$*" >> "$base/commands"
case "$1" in
    install) exec "$@" ;;
    systemctl) exit 0 ;;
    *) exit 9 ;;
esac
"#,
            );
            fixture.command(
                "curl",
                r#"
for arg do url="$arg"; done
case "$url" in
    */healthz) exit 0 ;;
    */varz) cat "$base/runtime" ;;
    *) exit 9 ;;
esac
"#,
            );
            fs::write(fixture.root.0.join("runtime"), "{\"version\":\"2.15.1\"}").unwrap();
            fixture
        }

        fn command(&self, name: &str, body: &str) {
            let file = self.commands.join(name);
            fs::write(
                &file,
                format!("#!/bin/sh\nset -eu\nbase=$(dirname \"$0\")/..\n{body}\n"),
            )
            .unwrap();
            fs::set_permissions(file, fs::Permissions::from_mode(0o700)).unwrap();
        }

        fn guest(&self) -> Guest<'_> {
            Guest {
                executable: &self.executable,
                unit: &self.unit,
                temp: &self.root.0,
                commands: Some(&self.commands),
                readiness_delay: Duration::ZERO,
            }
        }

        fn digest(&self) -> String {
            let digest = std::process::Command::new("sha256sum")
                .arg(self.root.0.join("release"))
                .output()
                .unwrap();
            String::from_utf8(digest.stdout)
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap()
                .to_owned()
        }
    }

    #[tokio::test]
    async fn only_restarts_when_the_binary_or_unit_changed_and_checks_running_version() {
        let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
        let fixture = Fixture::new();
        let digest = fixture.digest();
        let release = Release::new("v2.15.1", &digest, "aarch64").unwrap();
        let guest = fixture.guest();
        guest.install(&release).await.unwrap();
        guest.install(&release).await.unwrap();
        assert_eq!(fs::read_to_string(&fixture.unit).unwrap(), UNIT);
        let trace = fs::read_to_string(&fixture.trace).unwrap();
        assert_eq!(trace.matches("systemctl restart nats").count(), 1);
        assert_eq!(trace.matches("systemctl start nats").count(), 1);
        assert_eq!(trace.matches("systemctl daemon-reload").count(), 1);
        assert_eq!(trace.matches("wget").count(), 1);
        assert_eq!(trace.matches("sync").count(), 2);

        fs::write(fixture.root.0.join("runtime"), "{\"version\":\"2.14.0\"}").unwrap();
        assert_eq!(
            guest.install(&release).await.unwrap_err().detail,
            "NATS failed to become healthy"
        );
    }

    #[tokio::test]
    async fn refuses_bad_digest_before_extracting_or_touching_system_files() {
        let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
        let fixture = Fixture::new();
        let digest = "a".repeat(64);
        let release = Release::new("v2.15.1", &digest, "x86_64").unwrap();
        let failure = fixture.guest().install(&release).await.unwrap_err();
        assert_eq!(failure.exit, 7);
        assert!(failure.detail.contains("INTEGRITY MISMATCH"));
        assert_eq!(fs::read_to_string(&fixture.trace).unwrap(), "wget\n");
        assert!(!fixture.executable.exists());
        assert!(!fixture.unit.exists());
        assert!(fs::read_dir(&fixture.root.0).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with("amisad-nats.")));
    }

    #[test]
    fn pins_are_validated_before_launching_commands() {
        let digest = "a".repeat(64);
        assert!(Release::new("../../other", &digest, "x86_64").is_err());
        assert!(Release::new("v2.15.1", "invalid", "x86_64").is_err());
        assert!(Release::new("v2.15.1", &digest, "powerpc64").is_err());
        assert_eq!(
            Release::new("v2.15.1", &digest, "aarch64").unwrap().asset,
            "nats-server-v2.15.1-linux-arm64"
        );
    }
}
