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

fn endpoint(text: &str) -> Option<SocketAddr> {
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

fn edge_path(name: &str) -> Option<String> {
    if name.is_empty()
        || name.len() > 253
        || !name.as_bytes()[0].is_ascii_alphanumeric()
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
    {
        return None;
    }
    Some(format!("/log-upload/handoff/{name}.ip.txt"))
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
    let path = edge_path(String::from_utf8_lossy(&hostname.stdout).trim())
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
            let path = edge_path("amisad-edge-a").unwrap();
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
            edge_path("amisad-edge-a").as_deref(),
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
            assert!(edge_path(name).is_none(), "{name:?}");
        }
    }
}
