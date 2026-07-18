//! AmisAd POC shared plumbing: env-based config and a dependency-free HTTP
//! responder serving /health and /version. A real web framework replaces this
//! when services grow real routes; the two endpoints are the stable contract.

use std::io::{Read, Write};
use std::net::TcpListener;

pub struct ServiceInfo {
    pub name: &'static str,
    pub version: &'static str,
}

/// Bind 0.0.0.0:$PORT (default 8080) and answer /health and /version forever.
pub fn serve(info: ServiceInfo) -> std::io::Result<()> {
    let port = std::env::var("PORT").unwrap_or_else(|_| String::from("8080"));
    let addr = format!("0.0.0.0:{port}");
    let listener = TcpListener::bind(&addr)?;
    println!("{} {} listening on {addr}", info.name, info.version);
    for stream in listener.incoming() {
        let mut stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        let mut buf = [0u8; 1024];
        let n = stream.read(&mut buf).unwrap_or(0);
        let request = String::from_utf8_lossy(&buf[..n]);
        let path = request.split_whitespace().nth(1).unwrap_or("/");
        let (status, body) = match path {
            "/health" => (
                "200 OK",
                format!("{{\"status\":\"ok\",\"service\":\"{}\"}}", info.name),
            ),
            "/version" => (
                "200 OK",
                format!(
                    "{{\"service\":\"{}\",\"version\":\"{}\"}}",
                    info.name, info.version
                ),
            ),
            _ => ("404 Not Found", String::from("{\"error\":\"not found\"}")),
        };
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes());
    }
    Ok(())
}
