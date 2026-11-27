// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42028342-14c7-4f63-a124-4875ddd58cdd

mod bridge;

use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::Incoming;
use hyper::header::{CACHE_CONTROL, CONTENT_TYPE, HOST, ORIGIN};
use hyper::http::uri::Authority;
use hyper::server::conn::http1;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::convert::Infallible;
use std::net::{IpAddr, SocketAddr};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, Semaphore};
use tokio::task::JoinSet;

const PERSONAS: [&str; 11] = [
    "maya", "elena", "tom", "marcel", "kai", "priya", "ingrid", "dana", "alex", "sam", "pat",
];
const VM_NAMES: [&str; 3] = ["amisad-core", "amisad-edge-a", "amisad-edge-b"];

const REQUEST_LIMIT: usize = 1024 * 1024;
const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;
type Reply = Response<Full<Bytes>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    ByAct,
    DataView,
}

impl Mode {
    fn parse(name: &str) -> Option<Self> {
        match name {
            "by-act" => Some(Self::ByAct),
            "data-view" => Some(Self::DataView),
            _ => None,
        }
    }

    fn directory(self) -> &'static str {
        match self {
            Self::ByAct => "by-act",
            Self::DataView => "data-view",
        }
    }

    fn root_page(self) -> &'static str {
        match self {
            Self::ByAct => "ui/index.html",
            Self::DataView => "ui/actions.html",
        }
    }
}

struct Config {
    mode: Mode,
    port: u16,
    bind: String,
    root: PathBuf,
    ips: [String; 3],
    host_bridge: bool,
    share_personas: bool,
}

impl Config {
    fn parse(mut args: impl Iterator<Item = String>) -> Result<Self, String> {
        let mode = args
            .next()
            .as_deref()
            .and_then(Mode::parse)
            .ok_or_else(|| USAGE.to_owned())?;
        let mut flags = HashMap::new();
        let mut switches = HashSet::new();
        while let Some(name) = args.next() {
            if matches!(name.as_str(), "--host-bridge" | "--share-persona-passwords") {
                if !switches.insert(name.clone()) {
                    return Err(format!("Duplicate option {name}."));
                }
                continue;
            }
            if ![
                "--port",
                "--bind-address",
                "--demo-root",
                "--yuruna-root",
                "--core-ip",
                "--edge-a-ip",
                "--edge-b-ip",
            ]
            .contains(&name.as_str())
            {
                return Err(format!("Unknown option {name}. {USAGE}"));
            }
            let value = args
                .next()
                .ok_or_else(|| format!("Missing value for {name}."))?;
            if flags.insert(name.clone(), value).is_some() {
                return Err(format!("Duplicate option {name}."));
            }
        }
        let take = |key: &str| flags.get(key).map(String::as_str);
        let port = take("--port")
            .unwrap_or(if mode == Mode::ByAct { "8091" } else { "8092" })
            .parse::<u16>()
            .map_err(|_| "Expected a valid TCP port.".to_owned())?;
        let bind = take("--bind-address").unwrap_or("any").to_owned();
        let root = take("--demo-root")
            .map(PathBuf::from)
            .unwrap_or_else(|| Path::new("poc/demo").join(mode.directory()));
        let root = root
            .canonicalize()
            .map_err(|error| format!("Cannot locate demo files in {}: {error}", root.display()))?;
        let yuruna_root = take("--yuruna-root")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("YURUNA_ROOT").map(PathBuf::from));
        let logs = std::env::var_os("YURUNA_LOG_DIR")
            .map(PathBuf::from)
            .or_else(|| yuruna_root.map(|root| root.join("test/status/log")));
        let mut ips = [String::new(), String::new(), String::new()];
        for (index, flag) in ["--core-ip", "--edge-a-ip", "--edge-b-ip"]
            .iter()
            .enumerate()
        {
            let address = match take(flag) {
                Some(address) => address.to_owned(),
                None => logs
                    .as_ref()
                    .and_then(|logs| {
                        std::fs::read_to_string(
                            logs.join("handoff")
                                .join(format!("{}.ip.txt", VM_NAMES[index])),
                        )
                        .ok()
                    })
                    .unwrap_or_default(),
            };
            ips[index] = address.trim().to_owned();
        }
        Ok(Self {
            mode,
            port,
            bind,
            root,
            ips,
            host_bridge: switches.contains("--host-bridge"),
            share_personas: switches.contains("--share-persona-passwords"),
        })
    }
}

const USAGE: &str = "Usage: amisad-demo-host <by-act|data-view> [--port PORT] [--bind-address ADDRESS] [--demo-root DIR] [--yuruna-root DIR] [--core-ip ADDRESS] [--edge-a-ip ADDRESS] [--edge-b-ip ADDRESS] [--share-persona-passwords]";

#[derive(Default)]
struct Journal {
    latest: u64,
    events: Vec<Value>,
}

impl Journal {
    fn insert(&mut self, mut event: serde_json::Map<String, Value>) -> (u64, u64) {
        self.latest += 1;
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        event.insert("seq".into(), json!(self.latest));
        event.insert("ts".into(), json!(ts));
        self.events.push(Value::Object(event));
        (self.latest, ts)
    }
}

struct Demo {
    config: Config,
    local_ips: HashSet<IpAddr>,
    machine: String,
    journal: Mutex<Journal>,
    quiet_until: Mutex<HashMap<usize, Instant>>,
    bridge: Option<bridge::Bridge>,
}

fn loopback(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost") || host_ip(host).is_some_and(|ip| ip.is_loopback())
}

fn host_ip(host: &str) -> Option<IpAddr> {
    host.trim_matches(['[', ']']).parse::<IpAddr>().ok()
}

fn upstream_authority(host: &str, port: u16) -> Option<String> {
    if let Some(ip) = host_ip(host) {
        return Some(SocketAddr::new(ip, port).to_string());
    }
    host.bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
        .then(|| format!("{host}:{port}"))
}

fn response(
    status: StatusCode,
    content_type: &str,
    content: impl Into<Bytes>,
    no_store: bool,
) -> Reply {
    let mut out = Response::builder()
        .status(status)
        .header(CONTENT_TYPE, content_type);
    if no_store {
        out = out.header(CACHE_CONTROL, "no-store");
    }
    out.body(Full::new(content.into()))
        .expect("internally defined response parameters")
}

fn json_reply(status: StatusCode, value: Value) -> Reply {
    response(status, "application/json", value.to_string(), true)
}

fn failure(status: StatusCode, error: &str) -> Reply {
    json_reply(status, json!({"error":error}))
}

impl Demo {
    fn new(config: Config, bridge: Option<bridge::Bridge>) -> Self {
        let local_ips = if_addrs::get_if_addrs()
            .unwrap_or_default()
            .iter()
            .map(|interface| interface.addr.ip())
            .collect();
        let machine = std::env::var("COMPUTERNAME")
            .or_else(|_| std::env::var("HOSTNAME"))
            .or_else(|_| std::fs::read_to_string("/etc/hostname"))
            .unwrap_or_default()
            .trim()
            .to_owned();
        Self {
            config,
            local_ips,
            machine,
            journal: Mutex::new(Journal::default()),
            quiet_until: Mutex::default(),
            bridge,
        }
    }

    fn request_host(&self, request: &Request<Incoming>) -> Option<Authority> {
        let mut hosts = request.headers().get_all(HOST).iter();
        let host = hosts.next()?.to_str().ok()?.parse::<Authority>().ok()?;
        if hosts.next().is_some()
            || request
                .uri()
                .authority()
                .is_some_and(|authority| authority != &host)
        {
            return None;
        }
        let name = host.host();
        if loopback(name)
            || name.eq_ignore_ascii_case(&self.machine)
            || (!wildcard(&self.config.bind) && name.eq_ignore_ascii_case(&self.config.bind))
            || host_ip(name).is_some_and(|ip| self.local_ips.contains(&ip))
        {
            Some(host)
        } else {
            None
        }
    }

    async fn route(&self, request: Request<Incoming>, peer: SocketAddr) -> Reply {
        let Some(host) = self.request_host(&request) else {
            return failure(
                StatusCode::MISDIRECTED_REQUEST,
                "this demo answers only to its own host names",
            );
        };
        if request.method() != Method::GET
            && request.method() != Method::HEAD
            && !same_origin(&request, &host)
        {
            return failure(
                StatusCode::FORBIDDEN,
                "a page from another origin cannot change demo state",
            );
        }
        let path = request.uri().path();
        match path {
            "/api/personas" => {
                let can_read = self.config.share_personas
                    || (peer.ip().to_canonical().is_loopback() && loopback(host.host()));
                let data = if can_read {
                    self.host_resource("personas")
                        .await
                        .and_then(validate_personas)
                } else {
                    None
                };
                let placeholder = if can_read {
                    "<vault error: framework credential provider unavailable>"
                } else {
                    "<withheld: remote viewer>"
                };
                json_reply(
                    StatusCode::OK,
                    data.unwrap_or_else(|| {
                        json!(PERSONAS
                            .map(|username| json!({"username":username,"password":placeholder})))
                    }),
                )
            }
            "/api/topology" => json_reply(
                StatusCode::OK,
                json!({"core":self.config.ips[0],"edgeA":self.config.ips[1],"edgeB":self.config.ips[2]}),
            ),
            "/api/vms" if self.config.mode == Mode::DataView => {
                let data = self.host_resource("vms").await;
                let states = VM_NAMES.map(|name| {
                    data.as_ref()
                        .and_then(Value::as_array)
                        .and_then(|records| records.iter().find(|record| record["name"] == name))
                        .and_then(|record| record["state"].as_str())
                        .filter(|state| {
                            matches!(*state, "running" | "stopped" | "absent" | "unknown")
                        })
                        .unwrap_or("unknown")
                });
                json_reply(
                    StatusCode::OK,
                    json!((0..3)
                        .map(|i| {
                            json!({"name":VM_NAMES[i],"state":states[i],"ip":self.config.ips[i]})
                        })
                        .collect::<Vec<_>>()),
                )
            }
            "/api/subjects" if self.config.mode == Mode::DataView => {
                let subject = |name| {
                    amisad_common::sha256::hex_digest(format!("{name}|person|subject").as_bytes())
                        [..16]
                        .to_owned()
                };
                json_reply(
                    StatusCode::OK,
                    json!({"maya":subject("maya"),"pat":subject("pat")}),
                )
            }
            "/api/journal" | "/api/journal/reset" if self.config.mode == Mode::DataView => {
                self.journal(request).await
            }
            _ => {
                if let Some((index, port, tail)) = proxy_path(path) {
                    let query = request
                        .uri()
                        .query()
                        .map(|query| format!("?{query}"))
                        .unwrap_or_default();
                    let tail = format!("{tail}{query}");
                    self.proxy(index, port, &tail, request).await
                } else {
                    self.static_file(path).await
                }
            }
        }
    }

    async fn host_resource(&self, resource: &str) -> Option<Value> {
        self.bridge.as_ref()?.request(resource).await
    }

    async fn journal(&self, request: Request<Incoming>) -> Reply {
        let reset = request.uri().path().ends_with("/reset");
        if reset {
            if request.method() != Method::POST {
                return failure(
                    StatusCode::METHOD_NOT_ALLOWED,
                    "reset the journal with POST",
                );
            }
            let mut journal = self.journal.lock().await;
            journal.events.clear();
            let (seq, _) =
                journal.insert([("kind".to_owned(), json!("reset"))].into_iter().collect());
            return json_reply(StatusCode::OK, json!({"ok":true,"seq":seq}));
        }
        if request.method() == Method::POST {
            let value = body(request).await.ok().and_then(|bytes| {
                serde_json::from_slice::<serde_json::Map<String, Value>>(&bytes).ok()
            });
            let Some(event) = value else {
                return failure(
                    StatusCode::BAD_REQUEST,
                    "journal event must be a JSON object",
                );
            };
            let (seq, ts) = self.journal.lock().await.insert(event);
            return json_reply(StatusCode::CREATED, json!({"seq":seq,"ts":ts}));
        }
        let raw = request.uri().query().and_then(|query| {
            query
                .split('&')
                .find_map(|pair| pair.strip_prefix("since="))
        });
        let since = raw
            .and_then(|raw| percent_encoding::percent_decode_str(raw).decode_utf8().ok())
            .and_then(|value| value.parse::<i32>().ok())
            .unwrap_or_default();
        let journal = self.journal.lock().await;
        let events = journal
            .events
            .iter()
            .filter(|event| {
                event["seq"]
                    .as_i64()
                    .is_some_and(|seq| seq > i64::from(since))
            })
            .collect::<Vec<_>>();
        json_reply(
            StatusCode::OK,
            json!({"latest":journal.latest,"events":events}),
        )
    }

    async fn proxy(
        &self,
        index: usize,
        port: u16,
        tail: &str,
        request: Request<Incoming>,
    ) -> Reply {
        let name = VM_NAMES[index];
        let address = &self.config.ips[index];
        if address.is_empty() {
            let (vm, flag) = [
                ("amisad-core", "-CoreIp"),
                ("edge-a", "-EdgeAIp"),
                ("edge-b", "-EdgeBIp"),
            ][index];
            return failure(
                StatusCode::SERVICE_UNAVAILABLE,
                &format!("{vm} IP unresolved; restart with {flag} <ip>"),
            );
        }
        let Some(authority) = upstream_authority(address, port) else {
            return failure(
                StatusCode::BAD_GATEWAY,
                "The configured VM address is invalid.",
            );
        };
        let url = format!("http://{authority}{tail}");
        if self
            .quiet_until
            .lock()
            .await
            .get(&index)
            .is_some_and(|until| *until > Instant::now())
        {
            return json_reply(
                StatusCode::BAD_GATEWAY,
                json!({"error":format!("{address} did not answer a connection attempt; retry shortly"),"target":url}),
            );
        }
        let method = request.method().clone();
        let request_body = match body(request).await {
            Ok(body) => body,
            Err(_) => {
                return failure(
                    StatusCode::PAYLOAD_TOO_LARGE,
                    "Cannot read the request body.",
                )
            }
        };
        let deadline = match self.config.mode {
            Mode::ByAct => Duration::from_secs(60),
            Mode::DataView if method == Method::GET => Duration::from_secs(8),
            Mode::DataView => Duration::from_secs(30),
        };
        let connect_timeout = if self.config.mode == Mode::DataView {
            Duration::from_secs(3)
        } else {
            deadline
        };
        let result = tokio::time::timeout(
            deadline,
            exchange(&authority, tail, method, request_body, connect_timeout),
        )
        .await
        .unwrap_or_else(|_| Err(("The upstream request timed out.".to_owned(), false)));
        match result {
            Ok(reply) => reply,
            Err((error, unreachable)) => {
                if unreachable && self.config.mode == Mode::DataView {
                    self.quiet_until
                        .lock()
                        .await
                        .insert(index, Instant::now() + Duration::from_secs(30));
                }
                eprintln!("{name} proxy request failed: {error}");
                json_reply(StatusCode::BAD_GATEWAY, json!({"error":error,"target":url}))
            }
        }
    }

    async fn static_file(&self, raw_path: &str) -> Reply {
        let clean = percent_encoding::percent_decode_str(raw_path).decode_utf8();
        let not_found = || failure(StatusCode::NOT_FOUND, &format!("not found: {raw_path}"));
        let Ok(clean) = clean else {
            return not_found();
        };
        let root = &self.config.root;
        let path = clean.trim_start_matches('/');
        let (base, relative) = match path {
            "" => (root.clone(), self.config.mode.root_page()),
            "data" if self.config.mode == Mode::DataView => (root.clone(), "ui/data.html"),
            art if art.starts_with("art/") => (root.join("../../components/art"), &art[4..]),
            common if common.starts_with("common/") => (root.join("../common"), &common[7..]),
            _ => (root.clone(), path),
        };
        if relative.contains('\\')
            || Path::new(relative)
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
        {
            return not_found();
        }
        let Ok(base) = tokio::fs::canonicalize(base).await else {
            return not_found();
        };
        let Ok(file) = tokio::fs::canonicalize(base.join(relative)).await else {
            return not_found();
        };
        if !file.starts_with(&base)
            || !tokio::fs::metadata(&file)
                .await
                .is_ok_and(|info| info.is_file() && info.len() <= RESPONSE_LIMIT as u64)
        {
            return not_found();
        }
        let Ok(bytes) = tokio::fs::read(&file).await else {
            return not_found();
        };
        let kind = match file
            .extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_ascii_lowercase)
            .as_deref()
        {
            Some("html") => "text/html; charset=utf-8",
            Some("js") => "text/javascript; charset=utf-8",
            Some("css") => "text/css; charset=utf-8",
            Some("json") => "application/json",
            Some("svg") => "image/svg+xml",
            Some("png") => "image/png",
            Some("md") => "text/plain; charset=utf-8",
            Some("ico") => "image/x-icon",
            _ => "application/octet-stream",
        };
        response(StatusCode::OK, kind, bytes, false)
    }
}

async fn exchange(
    authority: &str,
    tail: &str,
    method: Method,
    body: Bytes,
    connect_timeout: Duration,
) -> Result<Reply, (String, bool)> {
    use std::io::ErrorKind;
    let stream = tokio::time::timeout(connect_timeout, TcpStream::connect(authority))
        .await
        .map_err(|_| ("The upstream connection timed out.".to_owned(), true))?
        .map_err(|error| {
            let unavailable = matches!(
                error.kind(),
                ErrorKind::TimedOut | ErrorKind::HostUnreachable | ErrorKind::NetworkUnreachable
            );
            (error.to_string(), unavailable)
        })?;
    let io_error = |error: hyper::Error| (error.to_string(), false);
    let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
        .await
        .map_err(io_error)?;
    // Dropping the request aborts its connection, including when an upstream
    // sends headers but disconnects or stalls partway through the body.
    let mut running = JoinSet::new();
    running.spawn(connection);
    let mut outgoing = Request::builder()
        .method(method)
        .uri(tail)
        .header(HOST, authority)
        .header("connection", "close");
    if !body.is_empty() {
        outgoing = outgoing.header(CONTENT_TYPE, "application/json");
    }
    let outgoing = outgoing
        .body(Full::new(body))
        .map_err(|error| (error.to_string(), false))?;
    let upstream = sender.send_request(outgoing).await.map_err(io_error)?;
    let status = upstream.status();
    let typ = upstream
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("application/json")
        .to_owned();
    let bytes = Limited::new(upstream.into_body(), RESPONSE_LIMIT)
        .collect()
        .await
        .map_err(|error| (error.to_string(), false))?
        .to_bytes();
    Ok(response(status, &typ, bytes, true))
}

async fn body(
    request: Request<Incoming>,
) -> Result<Bytes, Box<dyn std::error::Error + Send + Sync>> {
    Ok(Limited::new(request.into_body(), REQUEST_LIMIT)
        .collect()
        .await?
        .to_bytes())
}

fn validate_personas(value: Value) -> Option<Value> {
    let entries = value.as_array()?;
    let records: Option<Vec<_>> = PERSONAS
        .iter()
        .map(|name| {
            let entry = entries.iter().find(|item| item["username"] == *name)?;
            let password = entry["password"].as_str()?;
            Some(json!({"username":name,"password":password}))
        })
        .collect();
    records.map(Value::Array)
}

fn same_origin(request: &Request<Incoming>, host: &Authority) -> bool {
    let mut origins = request.headers().get_all(ORIGIN).iter();
    let Some(origin) = origins.next() else {
        return true;
    };
    if origins.next().is_some() {
        return false;
    }
    let port = host.port_u16().filter(|port| *port != 80);
    let own = match port {
        Some(port) => format!("http://{}:{port}", host.host()),
        None => format!("http://{}", host.host()),
    };
    origin
        .to_str()
        .is_ok_and(|origin| origin.trim_end_matches('/').eq_ignore_ascii_case(&own))
}

fn proxy_path(path: &str) -> Option<(usize, u16, &str)> {
    let rest = path.strip_prefix("/api/")?;
    let (name, _) = rest.split_once('/')?;
    let tail = &rest[name.len()..];
    match name {
        "edge-a" => Some((1, 8080, tail)),
        "edge-b" => Some((2, 8080, tail)),
        "core" => {
            let segment = tail.strip_prefix('/')?;
            let (port, _) = segment.split_once('/')?;
            if port.len() != 5 || !port.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            let port_number = port.parse::<u16>().ok()?;
            (30080..=30089).contains(&port_number).then_some((
                0,
                port_number,
                &segment[port.len()..],
            ))
        }
        _ => None,
    }
}

fn wildcard(bind: &str) -> bool {
    matches!(bind, "any" | "*" | "+" | "0.0.0.0" | "::")
}

async fn serve(listener: TcpListener, demo: Arc<Demo>) -> std::io::Result<()> {
    println!(
        "{} listening on http://{}/",
        demo.config.mode.directory(),
        listener.local_addr()?
    );
    let concurrency = Arc::new(Semaphore::new(64));
    let mut active = JoinSet::new();
    loop {
        tokio::select! {
            _ = active.join_next(), if !active.is_empty() => {}
            accepted = listener.accept() => {
                let (connection, peer) = accepted?;
                let Ok(permit) = concurrency.clone().try_acquire_owned() else { continue; };
                let demo = demo.clone();
                active.spawn(async move {
                    let _permit = permit;
                    let service = hyper::service::service_fn(|request| {
                        let demo = demo.clone();
                        async move { Ok::<_, Infallible>(demo.route(request, peer).await) }
                    });
                    let server = http1::Builder::new().keep_alive(false).timer(TokioTimer::new()).header_read_timeout(Duration::from_secs(5))
                        .serve_connection(TokioIo::new(connection), service);
                    let _ = tokio::time::timeout(Duration::from_secs(70), server).await;
                });
            }
        }
    }
}

#[cfg(unix)]
async fn stopping() -> std::io::Result<()> {
    use tokio::signal::unix::{signal, SignalKind};
    let mut terminate = signal(SignalKind::terminate())?;
    tokio::select! {
        result = tokio::signal::ctrl_c() => result,
        _ = terminate.recv() => Ok(()),
    }
}

#[cfg(not(unix))]
async fn stopping() -> std::io::Result<()> {
    tokio::signal::ctrl_c().await
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1).peekable();
    if args.peek().map(String::as_str) == Some("--help") {
        println!("{USAGE}");
        return Ok(());
    }
    let config = Config::parse(args)?;
    let bind = match config.bind.as_str() {
        "localhost" => "127.0.0.1",
        "::" => "::",
        name if wildcard(name) => "0.0.0.0",
        name => name,
    };
    let listener = TcpListener::bind((bind, config.port)).await?;
    let address = listener.local_addr()?;
    let loopback = if address.ip().is_loopback() || address.ip().is_unspecified() {
        None
    } else {
        Some(TcpListener::bind(("127.0.0.1", address.port())).await?)
    };
    let (bridge, stop) = if config.host_bridge {
        let (bridge, stop) = bridge::Bridge::open();
        (Some(bridge), Some(stop))
    } else {
        (None, None)
    };
    let demo = Arc::new(Demo::new(config, bridge));
    let service = async {
        if let Some(loopback) = loopback {
            tokio::try_join!(serve(listener, demo.clone()), serve(loopback, demo))?;
            Ok(())
        } else {
            serve(listener, demo).await
        }
    };
    tokio::select! {
        result = service => result?,
        result = stopping() => result?,
        () = async {
            if let Some(mut stop) = stop {
                let _ = stop.wait_for(|stopped| *stopped).await;
            } else {
                std::future::pending::<()>().await;
            }
        } => {}

    }
    Ok(())
}
