// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42e82f4a-648d-4ea9-b67b-0f36443952b7

use crate::{child, Failure};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::{header, Request};
use hyper_util::rt::TokioIo;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::task::JoinSet;
use tokio::time::{sleep, timeout};

pub(super) fn endpoint(text: &str) -> Option<SocketAddr> {
    let mut ip = None;
    let mut port = None;
    for line in text.lines() {
        let line = line.trim();
        let line = line.strip_prefix("export ").unwrap_or(line);
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim();
        let value = ['\'', '"']
            .iter()
            .find_map(|quote| value.strip_prefix(*quote)?.strip_suffix(*quote))
            .unwrap_or(value);
        match key {
            "YURUNA_STATUS_SERVICE_IP" => ip = value.parse::<IpAddr>().ok(),
            "YURUNA_STATUS_SERVICE_PORT" => {
                port = value.parse::<u16>().ok().filter(|port| *port > 0)
            }
            _ => {}
        }
    }
    Some(SocketAddr::new(ip?, port?))
}

fn edge_path(name: &str, root: &str) -> Option<String> {
    (!name.is_empty()
        && name.len() <= 253
        && name.as_bytes()[0].is_ascii_alphanumeric()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_')))
    .then(|| format!("/{root}/handoff/{name}.ip.txt"))
}

async fn publish(endpoint: SocketAddr, path: &str, address: IpAddr) -> Result<(), String> {
    let stream = timeout(Duration::from_secs(5), TcpStream::connect(endpoint))
        .await
        .map_err(|error| error.to_string())?
        .map_err(|error| error.to_string())?;
    let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
        .await
        .map_err(|error| error.to_string())?;
    let mut network = JoinSet::new();
    network.spawn(connection);
    let request = Request::put(path)
        .header(header::HOST, endpoint.to_string())
        .header(header::CONNECTION, "close")
        .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
        .body(Full::new(Bytes::from(address.to_string())))
        .map_err(|error| error.to_string())?;
    let response = sender
        .send_request(request)
        .await
        .map_err(|error| error.to_string())?;
    if response.status().as_u16() >= 400 {
        return Err(format!("status service returned {}", response.status()));
    }
    Limited::new(response.into_body(), 64 * 1024)
        .collect()
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}

async fn fetch_address(endpoint: SocketAddr, path: &str) -> Option<IpAddr> {
    let stream = TcpStream::connect(endpoint).await.ok()?;
    let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
        .await
        .ok()?;
    let mut network = JoinSet::new();
    network.spawn(connection);
    let request = Request::get(path)
        .header(header::HOST, endpoint.to_string())
        .header(header::CONNECTION, "close")
        .body(Full::new(Bytes::new()))
        .ok()?;
    let response = sender.send_request(request).await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body = Limited::new(response.into_body(), 1024)
        .collect()
        .await
        .ok()?
        .to_bytes();
    std::str::from_utf8(&body)
        .ok()?
        .trim_start_matches('\u{feff}')
        .trim()
        .parse()
        .ok()
}

async fn fetch_twice(endpoint: SocketAddr, path: &str) -> Option<IpAddr> {
    for _ in 0..2 {
        if let Ok(Some(address)) =
            timeout(Duration::from_secs(10), fetch_address(endpoint, path)).await
        {
            return Some(address);
        }
    }
    None
}

pub(super) async fn discover(name: &str, ip: &str, port: &str) -> Result<(), Failure> {
    if let Some(address) = resolve(name, ip, port).await? {
        println!("{address}");
    }
    Ok(())
}

pub(super) async fn resolve(name: &str, ip: &str, port: &str) -> Result<Option<IpAddr>, Failure> {
    let unavailable = || {
        Failure::new(
            2,
            "The native edge address lookup needs a status-service IP and port",
        )
    };
    let path = edge_path(name, "log").ok_or_else(unavailable)?;
    let port = port
        .parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .ok_or_else(unavailable)?;
    let target = SocketAddr::new(ip.parse().map_err(|_| unavailable())?, port);
    if let Ok(hosts) = child("getent", &["hosts", name], Duration::from_secs(10)).await {
        let hosts = String::from_utf8_lossy(&hosts.stdout);
        for line in hosts.lines() {
            let address = line
                .split_whitespace()
                .next()
                .and_then(|address| address.parse::<std::net::Ipv4Addr>().ok());
            if let Some(address) =
                address.filter(|address| address.octets()[..3] == [192, 168, 122])
            {
                return Ok(Some(address.into()));
            }
        }
    }
    if let Some(address) = fetch_twice(target, &path).await {
        return Ok(Some(address));
    }
    eprintln!("edge '{name}' handoff fetch from {target} failed; refreshing the host coordinates and retrying.");
    let locate = "/usr/local/lib/yuruna/yuruna-host-locate.sh";
    if child(locate, &[], Duration::from_secs(60)).await.is_err() {
        return Ok(None);
    }
    let refreshed = tokio::fs::read_to_string("/etc/yuruna/host.env")
        .await
        .ok()
        .and_then(|value| endpoint(&value))
        .unwrap_or(target);
    Ok(fetch_twice(refreshed, &path).await)
}

async fn probe(host_env: &Path) -> Result<(), String> {
    let host = tokio::fs::read_to_string(host_env)
        .await
        .map_err(|error| error.to_string())?;
    let endpoint = endpoint(&host).ok_or("host.env has no usable status-service endpoint")?;
    let identities = child("hostname", &["-I"], Duration::from_secs(5))
        .await
        .map_err(|error| error.detail)?;
    let address = String::from_utf8_lossy(&identities.stdout)
        .split_whitespace()
        .next()
        .and_then(|address| address.parse::<IpAddr>().ok())
        .ok_or("the guest has no usable IP address")?;
    let hostname = child("hostname", &[], Duration::from_secs(5))
        .await
        .map_err(|error| error.detail)?;
    let path = edge_path(
        String::from_utf8_lossy(&hostname.stdout).trim(),
        "log-upload",
    )
    .ok_or("the guest has no usable host name")?;
    timeout(Duration::from_secs(15), publish(endpoint, &path, address))
        .await
        .map_err(|error| error.to_string())?
}

pub async fn run() -> Result<(), Failure> {
    let path = Path::new("/etc/yuruna/host.env");
    for attempt in 1..=30 {
        // The host and the guest can both renew DHCP leases during retries.
        // Read the endpoint and the reported address for each request.
        match probe(path).await {
            Ok(()) => return Ok(()),
            Err(error) if attempt == 30 => return Err(Failure::new(1, error)),
            Err(_) => sleep(Duration::from_secs(5)).await,
        }
    }
    unreachable!("the last reporting attempt has returned");
}

#[cfg(target_os = "linux")]
pub async fn install() -> Result<(), Failure> {
    reporter_endpoint(Path::new("/etc/yuruna/host.env")).await?;
    let executable = std::env::current_exe()
        .map_err(|error| Failure::new(1, format!("Resolve the installed reporter: {error}")))?;
    install_units(
        Path::new("/etc/systemd/system"),
        &executable,
        "systemctl",
        "sync",
    )
    .await?;
    println!("amisad edge setup complete");
    Ok(())
}

#[cfg(target_os = "linux")]
async fn reporter_endpoint(path: &Path) -> Result<SocketAddr, Failure> {
    tokio::fs::read_to_string(path)
        .await
        .ok()
        .and_then(|value| endpoint(&value))
        .ok_or_else(|| Failure::new(2, "no host.env - cannot locate the host status service"))
}

#[cfg(target_os = "linux")]
async fn install_units(
    directory: &Path,
    executable: &Path,
    systemctl: &str,
    sync: &str,
) -> Result<(), Failure> {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;

    let path = executable
        .to_str()
        .filter(|path| executable.is_absolute() && !path.chars().any(char::is_control))
        .ok_or_else(|| Failure::new(1, "Invalid reporter executable path"))?;
    let argument = path
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('%', "%%")
        .replace('$', "$$");
    let service = format!(
        "# --- REGION: [Unit]
[Unit]
Description=Report this edge VM's IP to the Yuruna status service
Wants=network-online.target
After=network-online.target

# --- REGION: [Service]
[Service]
Type=oneshot
ExecStart=\"{argument}\" edge-report

# --- REGION: [Install]
[Install]
WantedBy=multi-user.target
"
    );
    let timer = "# --- REGION: [Unit]
[Unit]
Description=Keep this edge VM's reported IP current

[Timer]
# See https://yuruna.link/42010605-00c6
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s

# --- REGION: [Install]
[Install]
WantedBy=timers.target
";
    let failure = |error| Failure::new(1, format!("Install the edge reporter units: {error}"));
    let scratch = crate::Workspace::create(directory, ".amisad-edge-reporter").await?;
    let units = [
        ("amisad-ip-report.service", service.as_str()),
        ("amisad-ip-report.timer", timer),
    ];
    for (name, contents) in units {
        let path = scratch.0.join(name);
        let mut file = std::fs::File::create(path).map_err(failure)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o644))
            .map_err(failure)?;
        file.write_all(contents.as_bytes()).map_err(failure)?;
        file.sync_all().map_err(failure)?;
    }
    for (name, _) in units {
        std::fs::rename(scratch.0.join(name), directory.join(name)).map_err(failure)?;
    }
    let command_budget = Duration::from_secs(120);
    child(systemctl, &["daemon-reload"], command_budget).await?;
    child(
        systemctl,
        &["enable", units[0].0, units[1].0],
        command_budget,
    )
    .await?;
    child(systemctl, &["start", units[0].0], command_budget).await?;
    child(systemctl, &["start", units[1].0], command_budget).await?;
    // The baseline is snapshotted immediately after this command succeeds.
    child(sync, &[], command_budget).await?;
    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
#[tokio::test]
async fn requires_a_seeded_status_endpoint_before_installing_the_reporter() {
    let work = crate::Workspace::create(&std::env::temp_dir(), "amisad-reporter-seed")
        .await
        .unwrap();
    let seed = work.0.join("host.env");
    assert_eq!(reporter_endpoint(&seed).await.unwrap_err().exit, 2);
    tokio::fs::write(
        &seed,
        "YURUNA_STATUS_SERVICE_IP=192.0.2.4\nYURUNA_STATUS_SERVICE_PORT=8080\n",
    )
    .await
    .unwrap();
    assert_eq!(
        reporter_endpoint(&seed).await.unwrap().to_string(),
        "192.0.2.4:8080"
    );
}

#[cfg(all(test, target_os = "linux"))]
#[tokio::test]
async fn installs_units_for_the_verified_executable_and_flushes_after_start() {
    use std::{fs, os::unix::fs::PermissionsExt};

    let _fixture = crate::EXECUTABLE_FIXTURES.lock().await;
    let work = crate::Workspace::create(&std::env::temp_dir(), "amisad-reporter-test")
        .await
        .unwrap();
    let units = work.0.join("units");
    fs::create_dir(&units).unwrap();
    let executable = work.0.join("reporter % $ path").join("amisad-provision");
    let commands = work.0.join("commands");
    for name in ["systemctl", "sync"] {
        let script = work.0.join(name);
        fs::write(
            &script,
            "#!/bin/sh\nprintf '%s %s\\n' \"${0##*/}\" \"$*\" >> \"${0%/*}/commands\"\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    }
    install_units(
        &units,
        &executable,
        work.0.join("systemctl").to_str().unwrap(),
        work.0.join("sync").to_str().unwrap(),
    )
    .await
    .unwrap();
    let service = units.join("amisad-ip-report.service");
    assert!(fs::read_to_string(&service)
        .unwrap()
        .contains("reporter %% $$ path/amisad-provision\" edge-report"));
    assert_eq!(
        fs::metadata(service).unwrap().permissions().mode() & 0o777,
        0o644
    );
    assert!(fs::read_to_string(units.join("amisad-ip-report.timer"))
        .unwrap()
        .contains("OnUnitActiveSec=30s"));
    assert_eq!(fs::read_to_string(commands).unwrap(), "systemctl daemon-reload\nsystemctl enable amisad-ip-report.service amisad-ip-report.timer\nsystemctl start amisad-ip-report.service\nsystemctl start amisad-ip-report.timer\nsync \n");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_literal_addresses_and_ports_from_host_env() {
        let address =
            "YURUNA_STATUS_SERVICE_IP='192.0.2.17'\nexport YURUNA_STATUS_SERVICE_PORT=\"8080\"\n";
        assert_eq!(
            endpoint(address).unwrap(),
            "192.0.2.17:8080".parse().unwrap()
        );
        let ipv6 = "YURUNA_STATUS_SERVICE_IP=2001:db8::9\nYURUNA_STATUS_SERVICE_PORT=8080\n";
        assert_eq!(
            endpoint(ipv6).unwrap(),
            "[2001:db8::9]:8080".parse().unwrap()
        );
        assert!(
            endpoint("YURUNA_STATUS_SERVICE_IP=$(hostname)\nYURUNA_STATUS_SERVICE_PORT=8080")
                .is_none()
        );
        assert!(
            endpoint("YURUNA_STATUS_SERVICE_IP=127.0.0.1\nYURUNA_STATUS_SERVICE_PORT=0").is_none()
        );
    }

    #[tokio::test]
    async fn reads_an_edge_handoff_only_when_the_response_is_a_literal_ip() {
        use std::io::{BufRead, BufReader, Write};
        use std::net::TcpListener;
        let path = "/log/handoff/amisad-edge-a.ip.txt";
        for (status, body, expected) in [
            ("200 OK", "192.0.2.17\r\n", "192.0.2.17".parse().ok()),
            ("200 OK", "192.0.2.17; extra", None),
            ("404 Not Found", "192.0.2.17", None),
        ] {
            let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
            let endpoint = listener.local_addr().unwrap();
            let server = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut reader = BufReader::new(&stream);
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                assert_eq!(line, format!("GET {path} HTTP/1.1\r\n"));
                while line != "\r\n" {
                    line.clear();
                    assert_ne!(reader.read_line(&mut line).unwrap(), 0);
                }
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            });
            let actual = timeout(Duration::from_secs(3), fetch_address(endpoint, path))
                .await
                .unwrap();
            server.join().unwrap();
            assert_eq!(actual, expected);
        }
    }

    #[tokio::test]
    async fn publishes_the_raw_guest_ip_and_propagates_a_server_rejection() {
        use std::io::{BufRead, BufReader, Read, Write};
        use std::net::TcpListener;

        for status in ["201 Created", "503 Service Unavailable"] {
            let fixture = TcpListener::bind(("127.0.0.1", 0)).unwrap();
            let endpoint = fixture.local_addr().unwrap();
            let server = std::thread::spawn(move || {
                let (mut stream, _) = fixture.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut reader = BufReader::new(&stream);
                let mut line = String::new();
                assert_ne!(reader.read_line(&mut line).unwrap(), 0);
                assert_eq!(
                    line,
                    "PUT /log-upload/handoff/amisad-edge-a.ip.txt HTTP/1.1\r\n"
                );
                loop {
                    line.clear();
                    assert_ne!(reader.read_line(&mut line).unwrap(), 0);
                    if line == "\r\n" {
                        break;
                    }
                }
                let mut body = [0; 10];
                reader.read_exact(&mut body).unwrap();
                assert_eq!(&body, b"192.0.2.17");
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
                .unwrap();
            });
            let path = edge_path("amisad-edge-a", "log-upload").unwrap();
            let result = timeout(
                Duration::from_secs(3),
                publish(endpoint, &path, "192.0.2.17".parse().unwrap()),
            )
            .await
            .unwrap();
            server.join().unwrap();
            if status.starts_with("201") {
                assert!(result.is_ok());
            } else {
                assert!(result.unwrap_err().contains("503"));
            }
        }
    }

    #[test]
    fn uses_a_single_hostname_component_of_the_handoff_path() {
        assert_eq!(
            edge_path("amisad-edge-a", "log-upload").as_deref(),
            Some("/log-upload/handoff/amisad-edge-a.ip.txt")
        );
        for name in [
            "",
            "../other",
            "host/name",
            "host?role=other",
            "host%2fother",
            "ship\r\nnew",
        ] {
            assert!(edge_path(name, "log").is_none(), "{name:?}");
        }
    }
}
