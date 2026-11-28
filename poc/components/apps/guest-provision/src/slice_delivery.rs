// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42aa811f-cfba-4233-9239-7a77d98f0f27

use crate::{child, process_start, process_stop, slice_wait, Failure};
use base64::{engine::general_purpose::STANDARD, Engine};
use std::{
    env, io,
    net::{IpAddr, SocketAddr},
    path::Path,
    process::Stdio,
    time::Duration,
};
use tokio::{io::AsyncWriteExt, process::Command, time::timeout};

const UNIT: &str = "/etc/systemd/system/amisad-ip-report.service";
const INSTALL_ROOT: &str = "/usr/local/lib/yuruna/amisad-artifacts/";
const TOOL_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_TOKEN: usize = 16 * 1024;

fn installed_provisioner(unit: &str) -> Option<&str> {
    let path = unit.lines().find_map(|line| {
        line.strip_prefix("ExecStart=")?
            .strip_suffix(" edge-report")
    })?;
    // The reporter's systemd unit quotes its executable. The proof below
    // still permits only the literal immutable artifact path in either form.
    let path = path
        .strip_prefix('"')
        .and_then(|quoted| quoted.strip_suffix('"'))
        .unwrap_or(path);
    let id = path
        .strip_prefix(INSTALL_ROOT)?
        .strip_suffix("/amisad-provision")?;
    (id.len() == 64 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))).then_some(path)
}

fn quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn target_is_host(target: &str) -> bool {
    !target.is_empty()
        && !target.starts_with('-')
        && !target.ends_with('@')
        && target
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._@:[%]".contains(&byte))
}

async fn token() -> Vec<u8> {
    // A failing tool may print the Secret. Only emit a fixed diagnostic.
    let result = timeout(
        TOOL_TIMEOUT,
        Command::new("kubectl")
            .args([
                "-n",
                "amisad",
                "get",
                "secret",
                "amisad-ledger-write",
                "-o",
                "jsonpath={.data.token}",
            ])
            .stdin(Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await;
    if let Ok(Ok(output)) = result {
        if output.status.success() && output.stdout.len() <= MAX_TOKEN.div_ceil(3) * 4 {
            if let Ok(decoded) = STANDARD.decode(output.stdout) {
                if decoded.len() <= MAX_TOKEN && !decoded.contains(&0) && !decoded.contains(&b'\n')
                {
                    return decoded;
                }
            }
        }
    }
    eprintln!("!! no ledger write token from Secret amisad/amisad-ledger-write; slice-runtime starts without one");
    Vec::new()
}

async fn start_edge(ssh: &[&str], command: &str, mut secret: Vec<u8>) -> Result<(), Failure> {
    secret.push(b'\n');
    let run = async {
        let mut process = Command::new("ssh")
            .args(ssh)
            .arg(command)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        process
            .stdin
            .take()
            .ok_or(io::ErrorKind::BrokenPipe)?
            .write_all(&secret)
            .await?;
        process.wait().await
    };
    match timeout(TOOL_TIMEOUT, run).await {
        Ok(Ok(status)) if status.success() => Ok(()),
        Ok(Ok(status)) => Err(Failure::new(
            status
                .code()
                .and_then(|code| u8::try_from(code).ok())
                .unwrap_or(1),
            "Starting slice-runtime on the edge failed",
        )),
        Ok(Err(_)) => Err(Failure::new(1, "Starting slice-runtime on the edge failed")),
        Err(_) => Err(Failure::new(
            124,
            "Starting slice-runtime on the edge exceeded its deadline",
        )),
    }
}

pub(super) async fn run(
    target: &str,
    region: &str,
    ledger: &str,
    resource: &str,
    flags: &[String],
) -> Result<(), Failure> {
    let report_address = match flags {
        [] => false,
        [mode] if mode == "report-address" => true,
        _ => return Err(Failure::new(1, "Invalid slice delivery arguments")),
    };
    if let Some(address) = deliver(target, region, ledger, resource, report_address).await? {
        println!("AMISAD_SLICE_ADDRESS={address}");
    }
    Ok(())
}

fn first_address(bytes: &[u8]) -> Result<IpAddr, Failure> {
    std::str::from_utf8(bytes)
        .ok()
        .and_then(|text| text.split_whitespace().next())
        .and_then(|value| value.parse().ok())
        .ok_or_else(|| Failure::new(1, "The slice-runtime host has no usable address"))
}

fn after_effect(error: Failure) -> Failure {
    Failure::new(if error.exit == 2 { 1 } else { error.exit }, error.detail)
}

pub(super) async fn scenario(
    target: &str,
    region: &str,
    ledger: &str,
    resource: &str,
    allow_single: &str,
) -> Result<(), Failure> {
    let endpoint = start_scenario(target, region, ledger, resource, allow_single).await?;
    println!("AMISAD_SLICE_ENDPOINT={endpoint}");
    Ok(())
}

pub(super) async fn start_scenario(
    target: &str,
    region: &str,
    ledger: &str,
    resource: &str,
    allow_single: &str,
) -> Result<String, Failure> {
    let endpoint = if target.is_empty() {
        if allow_single != "1" {
            return Err(Failure::new(4, "edge unresolved, and AMISAD_ALLOW_SINGLE_VM is not set: refusing to assert a distributed scenario against a single-VM topology."));
        }
        println!("edge unresolved - slice-runtime on this VM (single-VM degraded fallback)");
        process_stop::run().await.map_err(after_effect)?;
        process_start::start_local(region, ledger, resource, token().await).await?;
        let local = child("hostname", &["-I"], TOOL_TIMEOUT)
            .await
            .map_err(after_effect)?;
        SocketAddr::new(first_address(&local.stdout)?, 8090)
    } else {
        println!("edge: {target}");
        let address = deliver(target, region, ledger, resource, true)
            .await?
            .ok_or_else(|| Failure::new(1, "The edge has no usable address"))?;
        SocketAddr::new(address, 8080)
    };
    let endpoint = format!("http://{endpoint}");
    slice_wait(&endpoint, Duration::from_secs(30), Duration::from_secs(2))
        .await
        .map_err(after_effect)?;
    Ok(endpoint)
}

async fn deliver(
    target: &str,
    region: &str,
    ledger: &str,
    resource: &str,
    report_address: bool,
) -> Result<Option<IpAddr>, Failure> {
    let delivery = prepare(target, region, ledger, resource).await?;
    transfer(&delivery, region, ledger, resource, report_address).await
}

struct Delivery<'a> {
    target: &'a str,
    key: String,
    provisioner: String,
}

async fn prepare<'a>(
    target: &'a str,
    region: &str,
    ledger: &str,
    resource: &str,
) -> Result<Delivery<'a>, Failure> {
    if !target_is_host(target)
        || [region, ledger, resource]
            .iter()
            .any(|value| value.chars().any(char::is_control))
    {
        return Err(Failure::new(1, "Invalid slice delivery target or settings"));
    }
    let home = env::var("REAL_HOME")
        .ok()
        .filter(|home| Path::new(home).is_absolute())
        .ok_or_else(|| Failure::new(1, "The AmisAd admin home is unavailable"))?;
    let key = format!("{home}/.ssh/amisad-demo-key");
    let options = ["-i", &key, "-o", "StrictHostKeyChecking=accept-new", "--"];
    let unit_command = format!("cat {UNIT}");
    let mut arguments = options.to_vec();
    arguments.extend([target, &unit_command]);
    let legacy = || Failure::new(2, "The edge has no enrolled slice provisioner");
    let unit = child("ssh", &arguments, TOOL_TIMEOUT)
        .await
        .map_err(|error| if error.exit == 1 { legacy() } else { error })?;
    let unit = std::str::from_utf8(&unit.stdout).map_err(|_| legacy())?;
    let provisioner = installed_provisioner(unit).ok_or_else(legacy)?;
    let help = format!("{provisioner} --help");
    *arguments.last_mut().unwrap() = &help;
    let capabilities = child("ssh", &arguments, TOOL_TIMEOUT).await?;
    let capabilities = String::from_utf8_lossy(&capabilities.stdout);
    if !capabilities.contains("slice-start") || !capabilities.contains("slice-stop") {
        return Err(legacy());
    }
    Ok(Delivery {
        target,
        key,
        provisioner: provisioner.to_owned(),
    })
}

async fn transfer(
    delivery: &Delivery<'_>,
    region: &str,
    ledger: &str,
    resource: &str,
    report_address: bool,
) -> Result<Option<IpAddr>, Failure> {
    let Delivery {
        target,
        key,
        provisioner,
    } = delivery;
    let options = [
        "-i",
        key.as_str(),
        "-o",
        "StrictHostKeyChecking=accept-new",
        "--",
    ];
    let mut ssh = options.to_vec();
    ssh.push(target);

    // Any failure past this point is authoritative. The caller must not
    // repeat a stop or transfer after an interrupted reply.
    let stop = format!("exec {provisioner} slice-stop");
    let mut arguments = ssh.clone();
    arguments.push(&stop);
    let stopped = child("ssh", &arguments, TOOL_TIMEOUT)
        .await
        .map_err(after_effect)?;
    print!("{}", String::from_utf8_lossy(&stopped.stdout));
    let destination = format!("{target}:/tmp/slice-runtime");
    let mut copy = options.to_vec();
    copy.extend(["target/release/slice-runtime", &destination]);
    child("scp", &copy, Duration::from_secs(120))
        .await
        .map_err(after_effect)?;
    let start = format!(
        "exec {provisioner} slice-start {} {} {}",
        quoted(region),
        quoted(ledger),
        quoted(resource)
    );
    start_edge(&ssh, &start, token().await)
        .await
        .map_err(after_effect)?;
    println!("edge-started");
    if report_address {
        *arguments.last_mut().unwrap() = "hostname -I";
        let result = child("ssh", &arguments, TOOL_TIMEOUT)
            .await
            .map_err(after_effect)?;
        return first_address(&result.stdout).map(Some);
    }
    Ok(None)
}

struct FailoverEdge {
    name: &'static str,
    region: &'static str,
    address: IpAddr,
    target: String,
}

impl FailoverEdge {
    async fn resolve(
        name: &'static str,
        region: &'static str,
        status_ip: &str,
        status_port: &str,
    ) -> Result<Self, Failure> {
        let address = crate::edge_report::resolve(name, status_ip, status_port)
            .await?
            .ok_or_else(|| {
                Failure::new(
                    7,
                    format!("edge {name} IP report missing - s004 requires both edges live"),
                )
            })?;
        let target = format!("{name}-admin@{address}");
        Ok(Self {
            name,
            region,
            address,
            target,
        })
    }

    fn delivery_error(&self, error: Failure) -> Failure {
        Failure::new(
            7,
            format!(
                "slice-runtime delivery to {} ({}) failed: {}",
                self.name, self.address, error.detail
            ),
        )
    }
}

pub(super) async fn failover(
    node: &str,
    status_ip: &str,
    status_port: &str,
) -> Result<(), Failure> {
    let core = node
        .parse::<IpAddr>()
        .map_err(|_| Failure::new(2, "The core node has no usable IP address"))?;
    let ledger = format!("http://{}", SocketAddr::new(core, 30081));
    let resource = format!("http://{}", SocketAddr::new(core, 30082));
    let a = FailoverEdge::resolve("amisad-edge-a", "region-a", status_ip, status_port).await?;
    let b = FailoverEdge::resolve("amisad-edge-b", "region-b", status_ip, status_port).await?;
    let prepare_error = |edge: &FailoverEdge, error: Failure| {
        if error.exit == 2 {
            error
        } else {
            edge.delivery_error(error)
        }
    };
    // Capability refusals still permit compatibility here. Neither edge has
    // been stopped, copied to, or started until both have been admitted.
    let first = prepare(&a.target, a.region, &ledger, &resource)
        .await
        .map_err(|error| prepare_error(&a, error))?;
    let second = prepare(&b.target, b.region, &ledger, &resource)
        .await
        .map_err(|error| prepare_error(&b, error))?;
    for (edge, plan) in [(&a, first), (&b, second)] {
        transfer(&plan, edge.region, &ledger, &resource, false)
            .await
            .map_err(|error| edge.delivery_error(error))?;
    }
    let first = format!("http://{}", SocketAddr::new(a.address, 8080));
    let second = format!("http://{}", SocketAddr::new(b.address, 8080));
    for target in [&first, &second] {
        slice_wait(target, Duration::from_secs(30), Duration::from_secs(2))
            .await
            .map_err(after_effect)?;
    }
    println!("slices: region-a at {first}, region-b at {second}");
    crate::scenarios::failover::run(node, &first, &second)
        .await
        .map_err(after_effect)
}
