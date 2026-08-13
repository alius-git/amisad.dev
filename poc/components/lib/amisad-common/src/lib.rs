// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
//! AmisAd POC shared plumbing, deliberately std-only (no third-party crates):
//! a small HTTP server (`serve_app`) and client (`request`), a minimal JSON
//! value type with parser and serializer (`json`), and SHA-256 (`sha256`) for
//! the hash-chained ledgers, self-tested against the FIPS 180-4 vectors. A
//! real web framework replaces these when the POC outgrows scenario work.

use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream, ToSocketAddrs};
use std::thread::sleep;
use std::time::Duration;

pub struct ServiceInfo {
    pub name: &'static str,
    pub version: &'static str,
}

pub struct Request {
    pub method: String,
    pub path: String,
    pub body: String,
}

pub struct Response {
    pub status: u16,
    pub body: String,
}

impl Response {
    pub fn json(status: u16, value: &json::Json) -> Response {
        Response { status, body: value.dump() }
    }
    pub fn error(status: u16, message: &str) -> Response {
        Response {
            status,
            body: json::obj(vec![("error", json::s(message))]).dump(),
        }
    }
}

fn status_text(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        409 => "Conflict",
        503 => "Service Unavailable",
        _ => "Internal Server Error",
    }
}

fn read_request(stream: &TcpStream) -> Option<Request> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    if reader.read_line(&mut line).ok()? == 0 {
        return None;
    }
    let mut parts = line.split_whitespace();
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    let mut content_length = 0usize;
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).ok()? == 0 {
            break;
        }
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse().unwrap_or(0);
            }
        }
    }
    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        reader.read_exact(&mut body).ok()?;
    }
    Some(Request {
        method,
        path,
        body: String::from_utf8_lossy(&body).into_owned(),
    })
}

fn write_response(stream: &TcpStream, response: &Response) {
    let payload = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        response.status,
        status_text(response.status),
        response.body.len(),
        response.body
    );
    let mut writer = stream;
    let _ = writer.write_all(payload.as_bytes());
}

/// Bind 0.0.0.0:$PORT (default 8080); /health and /version are built in,
/// everything else dispatches to `handler` with mutable service state.
/// Single-threaded by design: the POC call graph is acyclic, so sequential
/// request handling cannot deadlock.
pub fn serve_app<S>(
    info: ServiceInfo,
    mut state: S,
    handler: fn(&mut S, &Request) -> Response,
) -> std::io::Result<()> {
    let port = std::env::var("PORT").unwrap_or_else(|_| String::from("8080"));
    let addr = format!("0.0.0.0:{port}");
    let listener = TcpListener::bind(&addr)?;
    println!("{} {} listening on {addr}", info.name, info.version);
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        let _ = stream.set_read_timeout(Some(Duration::from_secs(20)));
        let request = match read_request(&stream) {
            Some(r) => r,
            None => continue,
        };
        let response = match (request.method.as_str(), request.path.as_str()) {
            ("GET", "/health") => Response::json(
                200,
                &json::obj(vec![("status", json::s("ok")), ("service", json::s(info.name))]),
            ),
            ("GET", "/version") => Response::json(
                200,
                &json::obj(vec![
                    ("service", json::s(info.name)),
                    ("version", json::s(info.version)),
                ]),
            ),
            _ => handler(&mut state, &request),
        };
        write_response(&stream, &response);
    }
    Ok(())
}

/// Legacy skeleton entry point: /health and /version only.
pub fn serve(info: ServiceInfo) -> std::io::Result<()> {
    serve_app(info, (), |_, _| Response::error(404, "not found"))
}

/// How long to wait before the one retried dial. These services are reached
/// through NodePorts, and a pod that moves leaves the DNAT rule aimed at an
/// address that no longer answers; kube-proxy reprograms the rule about a sync
/// interval later. Two seconds clears that gap without stretching a service
/// that is genuinely down into a long wait.
const CONNECT_RETRY_DELAY: Duration = Duration::from_secs(2);

/// Connect failures another dial can plausibly cure: the address was
/// unroutable, nothing was listening, or the handshake never completed. Each
/// describes a peer that was momentarily absent rather than a wrong address.
///
/// The retry is confined to the connect because nothing has been written at
/// that point. Re-sending a request whose bytes already reached the peer would
/// duplicate the non-idempotent POSTs this client carries -- a second need, a
/// second booking -- so a failure after the connect stays a failure.
fn connect_is_worth_retrying(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::HostUnreachable
            | ErrorKind::NetworkUnreachable
            | ErrorKind::ConnectionRefused
            | ErrorKind::TimedOut
    )
}

/// Minimal HTTP/1.1 client for plain-http service-to-service calls.
/// Returns (status, body). Only `http://host[:port]/path` URLs.
pub fn request(method: &str, url: &str, body: Option<&str>) -> Result<(u16, String), String> {
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| format!("unsupported url: {url}"))?;
    let (host_port, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match host_port.rsplit_once(':') {
        Some((h, p)) => (h, p.parse::<u16>().map_err(|_| format!("bad port in {url}"))?),
        None => (host_port, 80),
    };
    let addr = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("resolve {host_port}: {e}"))?
        .next()
        .ok_or_else(|| format!("no address for {host_port}"))?;
    let mut retried = false;
    let stream = loop {
        match TcpStream::connect_timeout(&addr, Duration::from_secs(10)) {
            Ok(stream) => break stream,
            Err(e) if !retried && connect_is_worth_retrying(&e) => {
                // Named on stderr so a cured gap leaves a trace: a run that
                // passes after this line took the retry, and a run that fails
                // after it was dialing an address that stayed unreachable.
                eprintln!(
                    "connect {host_port}: {e}; retrying once in {}s",
                    CONNECT_RETRY_DELAY.as_secs()
                );
                sleep(CONNECT_RETRY_DELAY);
                retried = true;
            }
            Err(e) => return Err(format!("connect {host_port}: {e}")),
        }
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let body_text = body.unwrap_or("");
    let payload = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_text}",
        body_text.len()
    );
    let mut writer = &stream;
    writer
        .write_all(payload.as_bytes())
        .map_err(|e| format!("send {url}: {e}"))?;
    let mut raw = Vec::new();
    let mut reader = &stream;
    reader
        .read_to_end(&mut raw)
        .map_err(|e| format!("read {url}: {e}"))?;
    let text = String::from_utf8_lossy(&raw);
    let mut lines = text.splitn(2, "\r\n");
    let status_line = lines.next().unwrap_or("");
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| format!("bad status line from {url}: {status_line}"))?;
    let response_body = match text.find("\r\n\r\n") {
        Some(i) => text[i + 4..].to_string(),
        None => String::new(),
    };
    Ok((status, response_body))
}

/// Four-way settlement split: network 5%, platform 5%, ads 0 (campaign-free
/// scenarios), seller the remainder — sums exactly by construction. Shared so
/// the sealed auto-close path (slice-runtime) and the manual booking
/// commitment (fabric-coordinator) cannot drift apart.
pub fn splits_for(value_cents: i64) -> (i64, i64, i64, i64) {
    let network = value_cents * 5 / 100;
    let platform = value_cents * 5 / 100;
    let ads = 0;
    let seller = value_cents - network - platform - ads;
    (seller, network, platform, ads)
}

/// Ad credit split (s005.attribution): agency 60%, creator the remainder —
/// sums to ad_cents exactly. Shared so the ledger money (coordinator) and the
/// attribution dashboard (ads-svc) cannot drift apart, like splits_for.
pub fn ad_split(ad_cents: i64) -> (i64, i64) {
    let agency = ad_cents * 60 / 100;
    (agency, ad_cents - agency)
}

pub mod sha256 {
    //! SHA-256 (FIPS 180-4), used for the hash-chained ledgers and derived ids.

    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];

    pub fn digest(data: &[u8]) -> [u8; 32] {
        let mut h: [u32; 8] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
            0x5be0cd19,
        ];
        let bit_len = (data.len() as u64).wrapping_mul(8);
        let mut msg = data.to_vec();
        msg.push(0x80);
        while msg.len() % 64 != 56 {
            msg.push(0);
        }
        msg.extend_from_slice(&bit_len.to_be_bytes());
        for chunk in msg.chunks(64) {
            let mut w = [0u32; 64];
            for i in 0..16 {
                w[i] = u32::from_be_bytes([
                    chunk[4 * i],
                    chunk[4 * i + 1],
                    chunk[4 * i + 2],
                    chunk[4 * i + 3],
                ]);
            }
            for i in 16..64 {
                let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
                let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
                w[i] = w[i - 16]
                    .wrapping_add(s0)
                    .wrapping_add(w[i - 7])
                    .wrapping_add(s1);
            }
            let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
                (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
            for i in 0..64 {
                let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
                let ch = (e & f) ^ ((!e) & g);
                let t1 = hh
                    .wrapping_add(s1)
                    .wrapping_add(ch)
                    .wrapping_add(K[i])
                    .wrapping_add(w[i]);
                let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
                let maj = (a & b) ^ (a & c) ^ (b & c);
                let t2 = s0.wrapping_add(maj);
                hh = g;
                g = f;
                f = e;
                e = d.wrapping_add(t1);
                d = c;
                c = b;
                b = a;
                a = t1.wrapping_add(t2);
            }
            h[0] = h[0].wrapping_add(a);
            h[1] = h[1].wrapping_add(b);
            h[2] = h[2].wrapping_add(c);
            h[3] = h[3].wrapping_add(d);
            h[4] = h[4].wrapping_add(e);
            h[5] = h[5].wrapping_add(f);
            h[6] = h[6].wrapping_add(g);
            h[7] = h[7].wrapping_add(hh);
        }
        let mut out = [0u8; 32];
        for (i, word) in h.iter().enumerate() {
            out[4 * i..4 * i + 4].copy_from_slice(&word.to_be_bytes());
        }
        out
    }

    pub fn hex_digest(data: &[u8]) -> String {
        digest(data).iter().map(|b| format!("{b:02x}")).collect()
    }
}

pub mod json {
    //! Minimal JSON value with parser and serializer. Numbers are f64
    //! internally; `as_i64` only answers for integral values, which covers
    //! the POC's integer-cents money model exactly.

    #[derive(Clone, Debug, PartialEq)]
    pub enum Json {
        Null,
        Bool(bool),
        Num(f64),
        Str(String),
        Arr(Vec<Json>),
        Obj(Vec<(String, Json)>),
    }

    pub fn s(value: &str) -> Json {
        Json::Str(value.to_string())
    }
    pub fn n(value: i64) -> Json {
        Json::Num(value as f64)
    }
    pub fn b(value: bool) -> Json {
        Json::Bool(value)
    }
    pub fn arr(items: Vec<Json>) -> Json {
        Json::Arr(items)
    }
    pub fn obj(pairs: Vec<(&str, Json)>) -> Json {
        Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    impl Json {
        pub fn get(&self, key: &str) -> Option<&Json> {
            match self {
                Json::Obj(pairs) => pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v),
                _ => None,
            }
        }
        pub fn as_str(&self) -> Option<&str> {
            match self {
                Json::Str(v) => Some(v),
                _ => None,
            }
        }
        pub fn as_bool(&self) -> Option<bool> {
            match self {
                Json::Bool(v) => Some(*v),
                _ => None,
            }
        }
        pub fn as_i64(&self) -> Option<i64> {
            match self {
                Json::Num(v) if v.fract() == 0.0 && v.abs() < 9.0e15 => Some(*v as i64),
                _ => None,
            }
        }
        pub fn as_arr(&self) -> Option<&Vec<Json>> {
            match self {
                Json::Arr(v) => Some(v),
                _ => None,
            }
        }
        pub fn str_of(&self, key: &str) -> Option<&str> {
            self.get(key)?.as_str()
        }
        pub fn i64_of(&self, key: &str) -> Option<i64> {
            self.get(key)?.as_i64()
        }
        pub fn bool_of(&self, key: &str) -> Option<bool> {
            self.get(key)?.as_bool()
        }

        pub fn dump(&self) -> String {
            let mut out = String::new();
            self.write(&mut out);
            out
        }

        fn write(&self, out: &mut String) {
            match self {
                Json::Null => out.push_str("null"),
                Json::Bool(v) => out.push_str(if *v { "true" } else { "false" }),
                Json::Num(v) => {
                    if v.fract() == 0.0 && v.abs() < 9.0e15 {
                        out.push_str(&format!("{}", *v as i64));
                    } else {
                        out.push_str(&format!("{v}"));
                    }
                }
                Json::Str(v) => write_string(v, out),
                Json::Arr(items) => {
                    out.push('[');
                    for (i, item) in items.iter().enumerate() {
                        if i > 0 {
                            out.push(',');
                        }
                        item.write(out);
                    }
                    out.push(']');
                }
                Json::Obj(pairs) => {
                    out.push('{');
                    for (i, (k, v)) in pairs.iter().enumerate() {
                        if i > 0 {
                            out.push(',');
                        }
                        write_string(k, out);
                        out.push(':');
                        v.write(out);
                    }
                    out.push('}');
                }
            }
        }
    }

    fn write_string(value: &str, out: &mut String) {
        out.push('"');
        for c in value.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out.push('"');
    }

    pub fn parse(text: &str) -> Result<Json, String> {
        let bytes: Vec<char> = text.chars().collect();
        let mut parser = Parser { chars: bytes, pos: 0 };
        parser.skip_ws();
        let value = parser.value()?;
        parser.skip_ws();
        if parser.pos != parser.chars.len() {
            return Err(format!("trailing characters at {}", parser.pos));
        }
        Ok(value)
    }

    struct Parser {
        chars: Vec<char>,
        pos: usize,
    }

    impl Parser {
        fn peek(&self) -> Option<char> {
            self.chars.get(self.pos).copied()
        }
        fn next(&mut self) -> Option<char> {
            let c = self.peek();
            if c.is_some() {
                self.pos += 1;
            }
            c
        }
        fn skip_ws(&mut self) {
            while matches!(self.peek(), Some(' ' | '\t' | '\n' | '\r')) {
                self.pos += 1;
            }
        }
        fn expect(&mut self, c: char) -> Result<(), String> {
            if self.next() == Some(c) {
                Ok(())
            } else {
                Err(format!("expected '{c}' at {}", self.pos))
            }
        }
        fn literal(&mut self, word: &str, value: Json) -> Result<Json, String> {
            for c in word.chars() {
                if self.next() != Some(c) {
                    return Err(format!("bad literal at {}", self.pos));
                }
            }
            Ok(value)
        }

        fn value(&mut self) -> Result<Json, String> {
            self.skip_ws();
            match self.peek() {
                Some('{') => self.object(),
                Some('[') => self.array(),
                Some('"') => Ok(Json::Str(self.string()?)),
                Some('t') => self.literal("true", Json::Bool(true)),
                Some('f') => self.literal("false", Json::Bool(false)),
                Some('n') => self.literal("null", Json::Null),
                Some(c) if c == '-' || c.is_ascii_digit() => self.number(),
                other => Err(format!("unexpected {other:?} at {}", self.pos)),
            }
        }

        fn object(&mut self) -> Result<Json, String> {
            self.expect('{')?;
            let mut pairs = Vec::new();
            self.skip_ws();
            if self.peek() == Some('}') {
                self.pos += 1;
                return Ok(Json::Obj(pairs));
            }
            loop {
                self.skip_ws();
                let key = self.string()?;
                self.skip_ws();
                self.expect(':')?;
                let value = self.value()?;
                pairs.push((key, value));
                self.skip_ws();
                match self.next() {
                    Some(',') => continue,
                    Some('}') => return Ok(Json::Obj(pairs)),
                    other => return Err(format!("expected ',' or '}}', got {other:?}")),
                }
            }
        }

        fn array(&mut self) -> Result<Json, String> {
            self.expect('[')?;
            let mut items = Vec::new();
            self.skip_ws();
            if self.peek() == Some(']') {
                self.pos += 1;
                return Ok(Json::Arr(items));
            }
            loop {
                let value = self.value()?;
                items.push(value);
                self.skip_ws();
                match self.next() {
                    Some(',') => continue,
                    Some(']') => return Ok(Json::Arr(items)),
                    other => return Err(format!("expected ',' or ']', got {other:?}")),
                }
            }
        }

        fn string(&mut self) -> Result<String, String> {
            self.expect('"')?;
            let mut out = String::new();
            loop {
                match self.next() {
                    None => return Err(String::from("unterminated string")),
                    Some('"') => return Ok(out),
                    Some('\\') => match self.next() {
                        Some('"') => out.push('"'),
                        Some('\\') => out.push('\\'),
                        Some('/') => out.push('/'),
                        Some('n') => out.push('\n'),
                        Some('r') => out.push('\r'),
                        Some('t') => out.push('\t'),
                        Some('b') => out.push('\u{0008}'),
                        Some('f') => out.push('\u{000c}'),
                        Some('u') => {
                            let first = self.hex4()?;
                            let code = if (0xd800..0xdc00).contains(&first) {
                                if self.next() != Some('\\') || self.next() != Some('u') {
                                    return Err(String::from("missing low surrogate"));
                                }
                                let low = self.hex4()?;
                                if !(0xdc00..0xe000).contains(&low) {
                                    return Err(String::from("invalid low surrogate"));
                                }
                                0x10000 + ((first - 0xd800) << 10) + (low - 0xdc00)
                            } else {
                                first
                            };
                            out.push(char::from_u32(code).unwrap_or('\u{fffd}'));
                        }
                        other => return Err(format!("bad escape {other:?}")),
                    },
                    Some(c) => out.push(c),
                }
            }
        }

        fn hex4(&mut self) -> Result<u32, String> {
            let mut value = 0u32;
            for _ in 0..4 {
                let c = self.next().ok_or("truncated \\u escape")?;
                value = value * 16
                    + c.to_digit(16).ok_or_else(|| format!("bad hex digit {c}"))?;
            }
            Ok(value)
        }

        fn number(&mut self) -> Result<Json, String> {
            let start = self.pos;
            while matches!(
                self.peek(),
                Some('-' | '+' | '.' | 'e' | 'E') | Some('0'..='9')
            ) {
                self.pos += 1;
            }
            let text: String = self.chars[start..self.pos].iter().collect();
            // Rust float parsing saturates overflow to infinity; dump() would
            // then emit non-JSON ("inf") that poisons persisted payloads.
            match text.parse::<f64>() {
                Ok(v) if v.is_finite() => Ok(Json::Num(v)),
                _ => Err(format!("bad number '{text}'")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_fips_vectors() {
        assert_eq!(
            sha256::hex_digest(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256::hex_digest(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn connect_retries_only_where_another_dial_helps() {
        // A pod that moved leaves the NodePort DNAT aimed at an address that
        // no longer answers: EHOSTUNREACH, "No route to host".
        assert!(connect_is_worth_retrying(&std::io::Error::from(
            ErrorKind::HostUnreachable
        )));
        assert!(connect_is_worth_retrying(&std::io::Error::from(
            ErrorKind::ConnectionRefused
        )));
        assert!(connect_is_worth_retrying(&std::io::Error::from(
            ErrorKind::TimedOut
        )));
        // A malformed or forbidden address is not a timing problem, and
        // dialing it again only spends the delay.
        assert!(!connect_is_worth_retrying(&std::io::Error::from(
            ErrorKind::InvalidInput
        )));
        assert!(!connect_is_worth_retrying(&std::io::Error::from(
            ErrorKind::PermissionDenied
        )));
    }

    #[test]
    fn spent_retry_keeps_the_original_connect_error() {
        // Nothing listens on port 1, so both dials are refused; the call costs
        // CONNECT_RETRY_DELAY and must still report the failure verbatim.
        let error = request("GET", "http://127.0.0.1:1/health", None).unwrap_err();
        assert!(error.starts_with("connect 127.0.0.1:1: "), "{error}");
    }

    #[test]
    fn json_roundtrip() {
        let value = json::obj(vec![
            ("name", json::s("serving set")),
            ("price_cents", json::n(12000)),
            ("auto_close", json::b(true)),
            ("tags", json::arr(vec![json::s("gift"), json::s("wish-list")])),
            ("note", json::Json::Null),
        ]);
        let text = value.dump();
        let parsed = json::parse(&text).expect("parse");
        assert_eq!(parsed, value);
        assert_eq!(parsed.i64_of("price_cents"), Some(12000));
        assert_eq!(parsed.bool_of("auto_close"), Some(true));
        assert_eq!(parsed.str_of("name"), Some("serving set"));
    }

    #[test]
    fn json_escapes() {
        let value = json::s("line\nquote\" slash\\ tab\t");
        let parsed = json::parse(&value.dump()).expect("parse");
        assert_eq!(parsed, value);
        let unicode = json::parse("\"\\u0041\\u00e9\"").expect("unicode");
        assert_eq!(unicode.as_str(), Some("Aé"));
    }

    #[test]
    fn json_rejects_unrepresentable_input() {
        // Overflowing numbers would dump as "inf" (not JSON) and poison
        // persisted hash-chained payloads on reload.
        assert!(json::parse("{\"x\":1e309}").is_err());
        assert!(json::parse("1e309").is_err());
        // A high surrogate must pair with a low surrogate (an unpaired one
        // would underflow the pairing subtraction and panic in debug builds).
        assert!(json::parse("\"\\ud800\\u0041\"").is_err());
        let paired = json::parse("\"\\ud83d\\ude00\"").expect("surrogate pair");
        assert_eq!(paired.as_str(), Some("😀"));
    }
}
