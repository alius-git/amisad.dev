// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42eb5b8e-576f-40a5-ad17-dee11947915b

use crate::{
    child, core_deploy, core_users, edge_report, runtime, scenarios::Endpoint, Failure, Workspace,
};
use std::{
    env,
    fs::{self, File},
    io::Read,
    net::SocketAddr,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const PLAN: &str = "/etc/yuruna/amisad-artifacts.json";
const HOST_SEED: &str = "/etc/yuruna/host.env";
const INSTALLER: &str = "/usr/local/lib/yuruna/install-rust-artifacts";
const LOCATOR: &str = "/usr/local/lib/yuruna/yuruna-host-locate.sh";
const TOOL: Duration = Duration::from_secs(30);
const PLAN_LIMIT: u64 = 1024 * 1024;

fn text(path: &Path) -> Result<&str, Failure> {
    path.to_str()
        .ok_or_else(|| Failure::new(7, "The AmisAd deployment path must be UTF-8"))
}

fn uses_runtime_bundle(plan: &Path) -> Result<bool, Failure> {
    let invalid = || Failure::new(7, "Invalid signed AmisAd runtime bundle plan");
    if !plan.symlink_metadata().is_ok_and(|meta| meta.is_file()) {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    File::open(plan)
        .and_then(|f| f.take(PLAN_LIMIT + 1).read_to_end(&mut bytes))
        .map_err(|_| invalid())?;
    if bytes.len() as u64 > PLAN_LIMIT {
        return Err(invalid());
    }
    let plan: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    match plan.as_object().ok_or_else(invalid)?.get("runtimeBundle") {
        None => Ok(false),
        Some(value) => value.as_bool().ok_or_else(invalid),
    }
}

pub(super) fn check_pin(pin: &str, allow_unverified: bool) -> Result<(), Failure> {
    if (pin.is_empty() && allow_unverified)
        || (pin.len() == 64 && pin.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        return Ok(());
    }
    Err(Failure::new(
        7,
        "DOWNLOAD NOT VERIFIED: AMISAD_PROJECT_ARCHIVE_SHA256 must contain the expected SHA-256.",
    ))
}

async fn host_coordinates() -> Option<SocketAddr> {
    if let Some(value) = tokio::fs::read_to_string(HOST_SEED)
        .await
        .ok()
        .and_then(|text| edge_report::endpoint(&text))
    {
        return Some(value);
    }
    let ip = env::var("YURUNA_STATUS_SERVICE_IP").ok()?.parse().ok()?;
    let port = env::var("YURUNA_STATUS_SERVICE_PORT").ok()?.parse().ok()?;
    (port != 0).then(|| SocketAddr::new(ip, port))
}

pub(super) async fn fetch_archive(archive: &Path) -> Result<(), Failure> {
    let mut error = Failure::new(2, "no host.env - cannot locate the host status service");
    for attempt in 0..2 {
        if attempt == 1 && Path::new(LOCATOR).is_file() {
            child(LOCATOR, &[], TOOL).await?;
        }
        if let Some(host) = host_coordinates().await {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let url = format!("http://{host}/yuruna-project-archive.tar.gz?nocache={nonce}");
            match child(
                "wget",
                &[
                    "--no-proxy",
                    "--timeout=30",
                    "--tries=2",
                    "-qO",
                    text(archive)?,
                    &url,
                ],
                Duration::from_secs(125),
            )
            .await
            {
                Ok(_) => return Ok(()),
                Err(failure) => error = failure,
            }
        }
        if attempt == 0 {
            eprintln!("AmisAd project archive fetch failed; refreshing the status service coordinates and retrying.");
        }
    }
    Err(error)
}

pub(super) async fn verify_archive(archive: &Path, pin: &str) -> Result<(), Failure> {
    if !archive
        .symlink_metadata()
        .is_ok_and(|entry| entry.is_file() && entry.len() != 0)
    {
        return Err(Failure::new(
            7,
            "The AmisAd project archive is not a regular file",
        ));
    }
    if pin.is_empty() {
        eprintln!("!! UNVERIFIED DOWNLOAD (AMISAD_ALLOW_UNVERIFIED=1): using the project archive without a SHA-256.");
        return Ok(());
    }
    let actual = digest(archive).await;
    if !actual.eq_ignore_ascii_case(pin) {
        return Err(Failure::new(7, format!("INTEGRITY MISMATCH: refusing the project archive (expected {pin}, actual {actual})")));
    }
    println!("  integrity: sha256 verified (the project archive)");
    Ok(())
}

async fn digest(path: &Path) -> String {
    let Ok(path) = text(path) else {
        return "<unreadable>".to_owned();
    };
    child("sha256sum", &[path], TOOL)
        .await
        .ok()
        .and_then(|value| String::from_utf8(value.stdout).ok())
        .and_then(|value| value.split_whitespace().next().map(str::to_owned))
        .unwrap_or_else(|| "<unreadable>".to_owned())
}

fn artifact_directory(cache: &Path, output: &[u8]) -> Result<PathBuf, Failure> {
    let value = std::str::from_utf8(output)
        .unwrap_or_default()
        .trim_end_matches(['\n', '\r']);
    let path = PathBuf::from(value);
    let valid = path.parent() == Some(cache)
        && path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|id| {
                id.len() == 64
                    && id
                        .bytes()
                        .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
            });
    if !valid || !path.symlink_metadata().is_ok_and(|entry| entry.is_dir()) {
        return Err(Failure::new(
            7,
            "The verified AmisAd runtime directory is unavailable",
        ));
    }
    Ok(path)
}

async fn install_artifacts(cache: &Path) -> Result<PathBuf, Failure> {
    let installer = Path::new(INSTALLER);
    if !installer
        .symlink_metadata()
        .is_ok_and(|entry| entry.is_file())
    {
        return Err(Failure::new(
            7,
            "The enrolled AmisAd artifact installer is unavailable",
        ));
    }
    let mut set = vec!["--plan-file", PLAN, text(cache)?];
    for binary in runtime::binaries() {
        set.push(binary);
    }
    set.push("framework-revision");
    let output = child(INSTALLER, &set, Duration::from_secs(1200))
        .await
        .map_err(|error| Failure::new(7, error.detail))?;
    artifact_directory(cache, &output.stdout)
}

fn download_route(row: &serde_json::Value) -> Option<String> {
    let path = row.get("permalink")?.as_str()?.strip_prefix("/s/")?;
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() != 5
        || parts.iter().any(|part| {
            part.is_empty()
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
                || matches!(*part, "." | "..")
        })
    {
        return None;
    }
    Some(format!("/download/{path}"))
}

async fn fetch_stash(
    endpoint: &Endpoint,
    label: &str,
    destination: &Path,
    pin: &str,
) -> Result<(), Failure> {
    endpoint
        .exchange("/healthz", None)
        .await
        .map_err(|_| Failure::new(3, format!("STASH UNREACHABLE at {}", endpoint.url())))?;
    let listing = endpoint
        .get(&format!(
            "/api/stashes?username=amisad-poc&filename={label}&limit=10"
        ))
        .await
        .map_err(|_| {
            Failure::new(
                3,
                format!("Could not list stash artifacts for amisad-poc/{label}"),
            )
        })?;
    let routes: Vec<_> = listing
        .get("stashes")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .take(10)
        .filter_map(download_route)
        .collect();
    if routes.is_empty() {
        return Err(Failure::new(
            3,
            format!("No stash artifact found for label amisad-poc/{label}"),
        ));
    }
    for route in &routes {
        let url = format!("{}{route}", endpoint.url());
        let result = child(
            "curl",
            &[
                "--disable",
                "--fail",
                "--silent",
                "--show-error",
                "--noproxy",
                "*",
                "--connect-timeout",
                "20",
                "--max-time",
                "1200",
                "-o",
                text(destination)?,
                &url,
            ],
            Duration::from_secs(1205),
        )
        .await;
        if result.is_ok()
            && destination
                .symlink_metadata()
                .is_ok_and(|file| file.is_file() && file.len() > 0)
        {
            if pin.is_empty() {
                eprintln!("!! UNVERIFIED DOWNLOAD (AMISAD_ALLOW_UNVERIFIED=1): using the stash binary archive without a SHA-256.");
                return Ok(());
            }
            if digest(destination).await.eq_ignore_ascii_case(pin) {
                println!("  integrity: sha256 verified (the stash binaries for {label})");
                return Ok(());
            }
            eprintln!("  stash upload {route} is not this pass's build; trying an older one");
        } else {
            eprintln!("  stash download of {route} failed; trying an older upload");
        }
        if let Err(error) = fs::remove_file(destination) {
            if error.kind() != std::io::ErrorKind::NotFound {
                return Err(Failure::new(
                    7,
                    format!("Could not discard a refused stash download: {error}"),
                ));
            }
        }
    }
    Err(Failure::new(7, format!(
        "INTEGRITY MISMATCH: none of the {} newest stash uploads for {label} are this pass's build (expected {pin})", routes.len()
    )))
}

async fn install_stash(downloads: &Path, allow_unverified: bool) -> Result<PathBuf, Failure> {
    let pin = env::var("AMISAD_BINARIES_SHA256").unwrap_or_default();
    if !(pin.is_empty() && allow_unverified
        || pin.len() == 64 && pin.bytes().all(|byte| byte.is_ascii_hexdigit()))
    {
        return Err(Failure::new(
            7,
            "DOWNLOAD NOT VERIFIED: AMISAD_BINARIES_SHA256 must contain the expected SHA-256.",
        ));
    }
    let host = env::var("STASH_HOST").map_err(|_| Failure::new(3, "STASH_HOST is empty"))?;
    let endpoint = Endpoint::parse(&format!("http://{host}"))
        .map_err(|_| Failure::new(3, "STASH_HOST is not a reachable host and port"))?;
    let archive = downloads.join("amisad-binaries.tgz");
    let label = format!("amisad-{}-binaries", env::consts::ARCH);
    fetch_stash(&endpoint, &label, &archive, &pin).await?;
    let candidate = downloads.join("stash");
    fs::create_dir(&candidate)
        .map_err(|error| Failure::new(7, format!("Could not stage stash binaries: {error}")))?;
    let mut args = vec!["-xzf", text(&archive)?, "-C", text(&candidate)?, "--"];
    for binary in runtime::binaries() {
        args.push(binary);
    }
    child("tar", &args, Duration::from_secs(120)).await?;
    Ok(candidate)
}

pub(super) fn available() -> Result<(), Failure> {
    println!("{}", uses_runtime_bundle(Path::new(PLAN))?);
    Ok(())
}

pub(super) async fn run(stash: bool) -> Result<(), Failure> {
    if uses_runtime_bundle(Path::new(PLAN))? == stash {
        return Err(Failure::new(
            7,
            "The AmisAd runtime plan does not select this release source",
        ));
    }
    let pin = env::var("AMISAD_PROJECT_ARCHIVE_SHA256").unwrap_or_default();
    let allow_unverified = env::var("AMISAD_ALLOW_UNVERIFIED").as_deref() == Ok("1");
    check_pin(&pin, allow_unverified)?;
    let home = core_users::login_home(core_users::login_uid()?).await?;
    let downloads = Workspace::create(&env::temp_dir(), "amisad-fetch").await?;
    let archive = downloads.0.join("project-poc.tar.gz");
    println!("== obtain project tree (helm charts and deploy layout) ==");
    fetch_archive(&archive).await?;
    verify_archive(&archive, &pin).await?;
    let artifact = if stash {
        println!("== download pinned binaries from the stash service ==");
        install_stash(&downloads.0, allow_unverified).await?
    } else {
        println!("== download and verify the enrolled AmisAd runtime bundle ==");
        install_artifacts(&downloads.0.join("runtime")).await?
    };
    let tree = Workspace::create(&home, ".amisad-deploy").await?;
    let project = tree.0.join("project");
    std::fs::create_dir(&project)
        .map_err(|error| Failure::new(7, format!("Create the deployment staging tree: {error}")))?;
    child(
        "tar",
        &["-xzf", text(&archive)?, "-C", text(&project)?],
        Duration::from_secs(120),
    )
    .await?;
    let destination = home.join("amisad.dev");
    let result = if stash {
        runtime::activate_stash(&project, &artifact, &destination)
    } else {
        runtime::activate(&project, &artifact, &destination)
    };
    result.map_err(|error| {
        Failure::new(
            7,
            format!("Could not activate the verified release: {error}"),
        )
    })?;
    env::set_current_dir(destination.join("poc"))
        .map_err(|error| Failure::new(7, format!("Open the deployed AmisAd project: {error}")))?;
    core_deploy::run().await
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    #[tokio::test]
    async fn stash_ignores_untrusted_routes_and_uses_the_upload_matching_the_pin() {
        let room = Workspace::create(&env::temp_dir(), "amisad-stash-fixture")
            .await
            .unwrap();
        let destination = room.0.join("binaries.tgz");
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let mut observed = Vec::new();
            for _ in 0..4 {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new();
                while !bytes.windows(4).any(|window| window == b"\r\n\r\n") {
                    let mut chunk = [0; 1024];
                    let size = socket.read(&mut chunk).await.unwrap();
                    assert!(size > 0 && bytes.len() < 4096);
                    bytes.extend_from_slice(&chunk[..size]);
                }
                let line = String::from_utf8(bytes).unwrap();
                let route = line.split_whitespace().nth(1).unwrap();
                let body = match route {
                    "/healthz" => "healthy",
                    "/api/stashes?username=amisad-poc&filename=amisad-x86_64-binaries&limit=10" => {
                        r#"{"stashes":[{"permalink":"/s/../2026/01/01/traverse"},{"permalink":"http://wrong.test/s/host/2026/01/01/outside"},{"permalink":"/s/host/2026/01/01/newer"},{"permalink":"/s/host/2026/01/01/current"}]}"#
                    }
                    "/download/host/2026/01/01/newer" => "other build",
                    "/download/host/2026/01/01/current" => "abc",
                    other => panic!("unexpected request {other}"),
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
                observed.push(route.to_owned());
            }
            observed
        });
        let endpoint = Endpoint::parse(&origin).unwrap();
        let pin = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD";
        fetch_stash(&endpoint, "amisad-x86_64-binaries", &destination, pin)
            .await
            .unwrap();
        assert_eq!(fs::read(destination).unwrap(), b"abc");
        let observed = server.await.unwrap();
        assert_eq!(
            observed[2..],
            [
                "/download/host/2026/01/01/newer",
                "/download/host/2026/01/01/current"
            ]
        );
    }

    #[tokio::test]
    async fn validates_the_bundle_plan_and_refuses_an_unrelated_artifact_directory() {
        let room = Workspace::create(&env::temp_dir(), "amisad-deploy-inputs")
            .await
            .unwrap();
        let plan = room.0.join("plan.json");
        assert!(uses_runtime_bundle(&plan).is_err());
        std::fs::write(&plan, b"{}").unwrap();
        assert!(!uses_runtime_bundle(&plan).unwrap());
        std::fs::write(&plan, br#"{"runtimeBundle":"true"}"#).unwrap();
        assert!(uses_runtime_bundle(&plan).is_err());
        std::fs::write(&plan, br#"{"runtimeBundle":true}"#).unwrap();
        assert!(uses_runtime_bundle(&plan).unwrap());
        let redirect = room.0.join("untrusted-plan.json");
        std::os::unix::fs::symlink(&plan, &redirect).unwrap();
        assert!(uses_runtime_bundle(&redirect).is_err());
        let artifacts = room.0.join("verified");
        let candidate = artifacts.join("a".repeat(64));
        std::fs::create_dir_all(&candidate).unwrap();
        assert_eq!(
            artifact_directory(&artifacts, text(&candidate).unwrap().as_bytes()).unwrap(),
            candidate
        );
        assert!(artifact_directory(&room.0, text(&candidate).unwrap().as_bytes()).is_err());
        let replacement = artifacts.join("b".repeat(64));
        std::os::unix::fs::symlink(&candidate, &replacement).unwrap();
        assert!(artifact_directory(&artifacts, text(&replacement).unwrap().as_bytes()).is_err());
    }

    #[tokio::test]
    async fn accepts_only_the_enrolled_project_archive_bytes() {
        let room = Workspace::create(&env::temp_dir(), "amisad-deploy-archive")
            .await
            .unwrap();
        let archive = room.0.join("project.tar.gz");
        let pin = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD";
        assert!(check_pin("", false).is_err());
        assert!(check_pin("", true).is_ok());
        assert!(check_pin(pin, false).is_ok());
        std::fs::write(&archive, b"abc").unwrap();
        verify_archive(&archive, pin).await.unwrap();
        std::fs::write(&archive, b"wrong bytes").unwrap();
        assert_eq!(verify_archive(&archive, pin).await.unwrap_err().exit, 7);
    }
}
