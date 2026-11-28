// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 4201333b-652c-4ad3-b338-0057a76ef824

use crate::{child, child_with_input, edge_report, Failure, Workspace};
use std::{
    env,
    fs::{self, File},
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    process::{Output, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::time::sleep;

const COMMAND: Duration = Duration::from_secs(30);
const DATABASE_INPUT: Duration = Duration::from_secs(300);
const GRANTS: &str = "GRANT USAGE ON SCHEMA ledger, seller, resource TO amisad;
GRANT SELECT, INSERT ON ledger.consent_ledger, ledger.settlement_ledger, ledger.attestation_ledger TO amisad;
GRANT SELECT, INSERT, UPDATE ON ledger.settlement_instructions TO amisad;
GRANT SELECT, INSERT, UPDATE ON seller.offers, seller.orders, seller.inventory TO amisad;
GRANT SELECT, INSERT, UPDATE ON resource.allocation_policies TO amisad;
";
const HBA: &str = "host amisad amisad 10.0.0.0/8 scram-sha-256 # amisad-pods
host amisad amisad 192.168.0.0/16 scram-sha-256 # amisad-pods
";

pub async fn run() -> Result<(), Failure> {
    let pin = env::var("AMISAD_SCHEMA_SHA256").unwrap_or_default();
    let allow_unverified = env::var("AMISAD_ALLOW_UNVERIFIED").as_deref() == Ok("1");
    let host_ip = env::var("YURUNA_STATUS_SERVICE_IP")
        .ok()
        .and_then(|value| value.parse::<IpAddr>().ok());
    let host_port = env::var("YURUNA_STATUS_SERVICE_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|port| *port > 0);
    let guest = Guest {
        host_env: Path::new("/etc/yuruna/host.env"),
        host_locator: Path::new("/usr/local/lib/yuruna/yuruna-host-locate.sh"),
        host_fallback: host_ip
            .zip(host_port)
            .map(|(ip, port)| SocketAddr::new(ip, port)),
        temp: &env::temp_dir(),
        commands: None,
        ready_delay: Duration::from_secs(2),
    };
    tokio::time::timeout(
        Duration::from_secs(890),
        guest.setup(&pin, allow_unverified),
    )
    .await
    .map_err(|_| Failure::new(124, "AmisAd database setup exceeded its deadline"))?
}

struct Guest<'a> {
    host_env: &'a Path,
    host_locator: &'a Path,
    host_fallback: Option<SocketAddr>,
    temp: &'a Path,
    commands: Option<&'a Path>,
    ready_delay: Duration,
}

impl Guest<'_> {
    fn tool(&self, name: &str) -> PathBuf {
        self.commands
            .map_or_else(|| PathBuf::from(name), |path| path.join(name))
    }

    async fn execute(
        &self,
        name: &str,
        args: &[&str],
        budget: Duration,
    ) -> Result<Output, Failure> {
        child(text(&self.tool(name))?, args, budget).await
    }

    async fn sudo(&self, args: &[&str]) -> Result<Output, Failure> {
        self.execute("sudo", args, COMMAND).await
    }

    async fn input(&self, args: &[&str], input: &Path) -> Result<(), Failure> {
        let file = File::open(input).map_err(io_failure)?;
        child_with_input(
            text(&self.tool("sudo"))?,
            args,
            DATABASE_INPUT,
            Stdio::from(file),
        )
        .await?;
        Ok(())
    }

    fn endpoint(&self) -> Option<SocketAddr> {
        fs::read_to_string(self.host_env)
            .ok()
            .and_then(|value| edge_report::endpoint(&value))
            .or(self.host_fallback)
    }

    async fn fetch_schema(&self, path: &Path) -> Result<(), Failure> {
        let mut result = Err(Failure::new(
            2,
            "no host.env - cannot locate the host status service",
        ));
        for attempt in 0..2 {
            if attempt == 1 && self.host_locator.is_file() {
                child(text(self.host_locator)?, &[], COMMAND).await?;
            }
            if let Some(host) = self.endpoint() {
                let nonce = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos();
                let url =
                    format!("http://{host}/yuruna-repo/project/poc/db/schema.sql?nocache={nonce}");
                result = self
                    .execute(
                        "wget",
                        &[
                            "--no-proxy",
                            "--timeout=30",
                            "--tries=2",
                            "-qO",
                            text(path)?,
                            &url,
                        ],
                        Duration::from_secs(65),
                    )
                    .await
                    .map(|_| ());
                if result.is_ok() {
                    return result;
                }
            }
            if attempt == 0 {
                eprintln!("host fetch of the AmisAd database schema failed; refreshing the host coordinates and retrying.");
            }
        }
        result
    }

    async fn verify_schema(
        &self,
        path: &Path,
        expected: &str,
        allow_unverified: bool,
    ) -> Result<(), Failure> {
        if !fs::symlink_metadata(path)
            .is_ok_and(|entry| entry.is_file() && entry.len() <= 16 * 1024 * 1024)
        {
            return Err(Failure::new(7, "Invalid AmisAd database schema input"));
        }
        if expected.is_empty() && allow_unverified {
            eprintln!("!! UNVERIFIED DOWNLOAD (AMISAD_ALLOW_UNVERIFIED=1): the database schema is used without a digest.");
            return Ok(());
        }
        let actual = self
            .execute("sha256sum", &[text(path)?], COMMAND)
            .await
            .ok();
        let actual = actual
            .as_ref()
            .and_then(|output| std::str::from_utf8(&output.stdout).ok())
            .and_then(|stdout| stdout.split_whitespace().next())
            .unwrap_or("<unreadable>");
        if !actual.eq_ignore_ascii_case(expected) {
            return Err(Failure::new(7, format!(
                "INTEGRITY MISMATCH: refusing AmisAd database schema (expected {expected}, actual {actual})"
            )));
        }
        println!("  integrity: sha256 verified (the database schema)");
        Ok(())
    }

    fn installed(&self, name: &str) -> bool {
        if let Some(directory) = self.commands {
            return directory.join(name).is_file();
        }
        env::var_os("PATH")
            .is_some_and(|paths| env::split_paths(&paths).any(|path| path.join(name).is_file()))
    }

    async fn setup(&self, pin: &str, allow_unverified: bool) -> Result<(), Failure> {
        if pin.is_empty() {
            if !allow_unverified {
                return Err(Failure::new(7, "DOWNLOAD NOT VERIFIED: AMISAD_SCHEMA_SHA256 is empty. Set the expected digest before running the schema setup."));
            }
        } else if pin.len() != 64 || !pin.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(Failure::new(
                7,
                "DOWNLOAD NOT VERIFIED: AMISAD_SCHEMA_SHA256 is not a SHA-256.",
            ));
        }

        let work = Workspace::create(self.temp, "amisad-fetch").await?;
        let schema = work.0.join("schema.sql");
        self.fetch_schema(&schema).await?;
        self.verify_schema(&schema, pin, allow_unverified).await?;
        if !self.installed("psql") {
            let install = Duration::from_secs(900);
            self.execute("sudo", &["apt-get", "update", "-y"], install)
                .await?;
            self.execute(
                "sudo",
                &[
                    "env",
                    "DEBIAN_FRONTEND=noninteractive",
                    "apt-get",
                    "install",
                    "-y",
                    "postgresql",
                ],
                install,
            )
            .await?;
        }
        self.sudo(&["systemctl", "enable", "--now", "postgresql"])
            .await?;
        for _ in 0..30 {
            if self
                .execute(
                    "sudo",
                    &["-u", "postgres", "pg_isready", "-q"],
                    Duration::from_secs(5),
                )
                .await
                .is_ok()
            {
                break;
            }
            sleep(self.ready_delay).await;
        }
        self.sudo(&["-u", "postgres", "pg_isready"]).await?;

        if !self
            .exists("SELECT 1 FROM pg_database WHERE datname='amisad'")
            .await?
        {
            self.sudo(&["-u", "postgres", "createdb", "amisad"]).await?;
        }
        self.input(
            &[
                "-u",
                "postgres",
                "psql",
                "-v",
                "ON_ERROR_STOP=1",
                "-d",
                "amisad",
                "-f",
                "-",
            ],
            &schema,
        )
        .await?;
        if !self
            .exists("SELECT 1 FROM pg_roles WHERE rolname='amisad'")
            .await?
        {
            self.sudo(&[
                "-u",
                "postgres",
                "psql",
                "-v",
                "ON_ERROR_STOP=1",
                "-c",
                "CREATE ROLE amisad LOGIN",
            ])
            .await?;
        }
        let grants = work.0.join("grants.sql");
        fs::write(&grants, GRANTS).map_err(io_failure)?;
        self.input(
            &[
                "-u",
                "postgres",
                "psql",
                "-v",
                "ON_ERROR_STOP=1",
                "-d",
                "amisad",
            ],
            &grants,
        )
        .await?;
        self.sudo(&[
            "-u",
            "postgres",
            "psql",
            "-c",
            "ALTER SYSTEM SET listen_addresses = '*'",
        ])
        .await?;
        self.configure_hba(&work.0).await?;
        self.sudo(&["systemctl", "restart", "postgresql"]).await?;
        self.sudo(&["-u", "postgres", "pg_isready"]).await?;
        println!("AmisAd database ready (role amisad, pod access enabled)");
        Ok(())
    }

    async fn exists(&self, query: &str) -> Result<bool, Failure> {
        let result = self.sudo(&["-u", "postgres", "psql", "-tc", query]).await?;
        let stdout = std::str::from_utf8(&result.stdout)
            .map_err(io_failure)?
            .trim();
        match stdout {
            "1" => Ok(true),
            "" => Ok(false),
            _ => Err(Failure::new(
                1,
                "Unrecognized database or role query result",
            )),
        }
    }

    async fn configure_hba(&self, work: &Path) -> Result<(), Failure> {
        let output = self
            .sudo(&["-u", "postgres", "psql", "-tAc", "SHOW hba_file"])
            .await?;
        let path = std::str::from_utf8(&output.stdout)
            .map_err(io_failure)?
            .trim();
        if !Path::new(path).is_absolute() || path.chars().any(char::is_control) {
            return Err(Failure::new(
                1,
                "PostgreSQL did not identify a valid HBA file",
            ));
        }
        let existing = self.sudo(&["cat", path]).await?;
        if !std::str::from_utf8(&existing.stdout)
            .map_err(io_failure)?
            .contains("amisad-pods")
        {
            let additions = work.join("hba");
            fs::write(&additions, HBA).map_err(io_failure)?;
            self.input(&["tee", "-a", path], &additions).await?;
        }
        Ok(())
    }
}

fn text(path: &Path) -> Result<&str, Failure> {
    path.to_str()
        .ok_or_else(|| Failure::new(1, "Invalid database setup path"))
}

fn io_failure(error: impl std::fmt::Display) -> Failure {
    Failure::new(1, error.to_string())
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture {
        root: Workspace,
        programs: PathBuf,
        host: PathBuf,
    }

    impl Fixture {
        fn new() -> Self {
            let command = std::process::Command::new("mktemp")
                .arg("-d")
                .output()
                .unwrap();
            assert!(command.status.success());
            let root = PathBuf::from(String::from_utf8(command.stdout).unwrap().trim());
            let programs = root.join("bin");
            let host = root.join("host.env");
            fs::create_dir(&programs).unwrap();
            fs::write(
                &host,
                "YURUNA_STATUS_SERVICE_IP=192.0.2.10\nYURUNA_STATUS_SERVICE_PORT=8080\n",
            )
            .unwrap();
            fs::write(root.join("remote-schema"), "CREATE SCHEMA ledger;\n").unwrap();
            fs::write(
                root.join("pg_hba.conf"),
                "# existing operator configuration\n",
            )
            .unwrap();
            let fixture = Self {
                root: Workspace(root),
                programs,
                host,
            };
            fixture.command("psql", ":");
            fixture.command("sha256sum", "exec sha256sum \"$@\"");
            fixture.command(
                "wget",
                r#"
while [ "$1" != -qO ]; do shift; done
echo "$3" >> "$base/fetches"
cp -- "$base/remote-schema" "$2"
"#,
            );
            fixture.command(
                "sudo",
                r#"
echo "$*" >> "$base/sudo-trace"
if [ "$1" = -u ]; then shift 2; fi
case "$*" in
    'psql -tc SELECT 1 FROM pg_database'*)
        [ ! -e "$base/fail-catalog" ] || exit 17
        if [ -e "$base/database" ]; then echo ' 1'; fi
        ;;
    'createdb amisad') touch "$base/database" ;;
    'psql -tc SELECT 1 FROM pg_roles'*)
        if [ -e "$base/role" ]; then echo ' 1'; fi
        ;;
    *'CREATE ROLE amisad LOGIN') touch "$base/role" ;;
    'psql -v ON_ERROR_STOP=1 -d amisad -f -') cat > "$base/applied-schema" ;;
    'psql -v ON_ERROR_STOP=1 -d amisad') cat > "$base/applied-grants" ;;
    'psql -tAc SHOW hba_file')
        printf '%s\n' "$(cd "$base" && pwd)/pg_hba.conf"
        ;;
    'cat '*|'tee -a '*) exec "$@" ;;
    'pg_isready'*|'systemctl '*|'psql -c ALTER SYSTEM'*) : ;;
    *) exit 12 ;;
esac
"#,
            );
            fixture
        }

        fn command(&self, name: &str, body: &str) {
            let path = self.programs.join(name);
            fs::write(
                &path,
                format!("#!/bin/sh\nset -eu\nbase=$(dirname \"$0\")/..\n{body}\n"),
            )
            .unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        }

        fn guest(&self) -> Guest<'_> {
            Guest {
                host_env: &self.host,
                host_locator: Path::new("/no-host-locator-for-this-fixture"),
                host_fallback: None,
                temp: &self.root.0,
                commands: Some(&self.programs),
                ready_delay: Duration::ZERO,
            }
        }

        fn pin(&self) -> String {
            let output = std::process::Command::new("sha256sum")
                .arg(self.root.0.join("remote-schema"))
                .output()
                .unwrap();
            String::from_utf8(output.stdout)
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap()
                .to_owned()
        }

        fn read(&self, name: &str) -> String {
            fs::read_to_string(self.root.0.join(name)).unwrap()
        }
    }

    #[tokio::test]
    async fn rejected_schema_never_invokes_sudo() {
        let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
        let fixture = Fixture::new();
        let guest = fixture.guest();
        assert_eq!(guest.setup("", false).await.unwrap_err().exit, 7);
        assert!(!fixture.root.0.join("fetches").exists());
        let error = guest.setup(&"a".repeat(64), false).await.unwrap_err();
        assert_eq!(error.exit, 7);
        assert!(error.detail.contains("INTEGRITY MISMATCH"));
        assert!(!fixture.root.0.join("sudo-trace").exists());
        assert_eq!(
            fixture.read("pg_hba.conf"),
            "# existing operator configuration\n"
        );
    }

    #[tokio::test]
    async fn successful_setup_uses_checked_schema_and_keeps_existing_hba_rows() {
        let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
        let fixture = Fixture::new();
        let digest = fixture.pin().to_uppercase();
        let guest = fixture.guest();
        guest.setup(&digest, false).await.unwrap();
        guest.setup(&digest, false).await.unwrap();
        assert_eq!(
            fixture.read("applied-schema"),
            fixture.read("remote-schema")
        );
        assert_eq!(fixture.read("applied-grants"), GRANTS);
        assert_eq!(
            fixture.read("pg_hba.conf"),
            format!("# existing operator configuration\n{HBA}")
        );
        let trace = fixture.read("sudo-trace");
        assert_eq!(trace.matches("createdb amisad").count(), 1);
        assert_eq!(trace.matches("CREATE ROLE amisad LOGIN").count(), 1);
        assert_eq!(trace.matches("tee -a").count(), 1);
        assert!(fixture
            .read("fetches")
            .starts_with("http://192.0.2.10:8080/yuruna-repo/project/poc/db/schema.sql?nocache="));
    }

    #[tokio::test]
    async fn failed_catalog_query_never_creates_database_or_applies_schema() {
        let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
        let fixture = Fixture::new();
        fs::write(fixture.root.0.join("fail-catalog"), "").unwrap();
        let error = fixture
            .guest()
            .setup(&fixture.pin(), false)
            .await
            .unwrap_err();
        assert_eq!(error.exit, 17);
        assert!(!fixture.root.0.join("database").exists());
        assert!(!fixture.root.0.join("applied-schema").exists());
    }
}
