// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42a213ce-83c5-4071-9071-ddb88d146d42

mod edge_report;

use bytes::Bytes;
use http_body_util::{BodyExt, Empty, Limited};
use hyper::{header, Request};
use hyper_util::rt::TokioIo;
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::process::{ExitCode, Output, Stdio};
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::process::Command;
use tokio::task::JoinSet;
use tokio::time::{sleep, timeout, Instant};

const SERVICES: [&str; 10] = [
    "seller-svc",
    "resource-svc",
    "ads-svc",
    "insights-svc",
    "platform-svc",
    "audit-svc",
    "connect-svc",
    "fabric-coordinator",
    "identity-mock",
    "ledger-svc",
];
const POLL_BUDGET: Duration = Duration::from_secs(300);
const POLL_DELAY: Duration = Duration::from_secs(1);

#[derive(Debug)]
struct Failure {
    exit: u8,
    detail: String,
}

impl Failure {
    fn new(exit: u8, detail: impl Into<String>) -> Self {
        Self {
            exit,
            detail: detail.into(),
        }
    }
}

async fn child(program: &str, arguments: &[&str], budget: Duration) -> Result<Output, Failure> {
    let mut command = Command::new(program);
    command
        .args(arguments)
        .stdin(Stdio::null())
        .kill_on_drop(true);
    let result = timeout(budget, command.output())
        .await
        .map_err(|_| {
            Failure::new(
                124,
                format!("{program} exceeded its {}s deadline", budget.as_secs()),
            )
        })?
        .map_err(|error| Failure::new(1, format!("{program}: {error}")))?;
    if result.status.success() {
        return Ok(result);
    }
    let stderr: Vec<u8> = result.stderr.into_iter().take(4096).collect();
    let stdout: Vec<u8> = result.stdout.into_iter().take(4096).collect();
    let stderr = String::from_utf8_lossy(&stderr);
    let stdout = String::from_utf8_lossy(&stdout);
    let exit = result
        .status
        .code()
        .and_then(|code| u8::try_from(code).ok())
        .unwrap_or(1);
    Err(Failure::new(
        exit,
        format!(
            "{program} exited {exit}: {} {}",
            stderr.trim(),
            stdout.trim()
        ),
    ))
}

async fn poll<F, Fut>(budget: Duration, delay: Duration, mut action: F) -> Result<(), Failure>
where
    F: FnMut(Duration) -> Fut,
    Fut: Future<Output = Result<(), Failure>>,
{
    let deadline = Instant::now() + budget;
    let mut last = Failure::new(1, "no probe started within the readiness budget");
    loop {
        let now = Instant::now();
        if now >= deadline {
            return Err(last);
        }
        let attempt = (deadline - now).min(Duration::from_secs(2));
        match timeout(attempt, action(attempt)).await {
            Ok(Ok(())) => return Ok(()),
            Ok(Err(failure)) => last = failure,
            Err(_) => last = Failure::new(124, "readiness probe timed out"),
        }
        sleep(
            deadline
                .saturating_duration_since(Instant::now())
                .min(delay),
        )
        .await;
    }
}

trait Cluster {
    async fn repair_kube_ownership(&self);
    async fn kubectl(&self, arguments: &[&str], budget: Duration) -> Result<(), Failure>;
    async fn flannel_ready(&self) -> Result<(), Failure>;
    async fn node_ip(&self) -> Result<IpAddr, Failure>;
    async fn health(&self, ip: IpAddr, port: u16) -> Result<(), Failure>;
}

struct LocalCluster;

impl Cluster for LocalCluster {
    async fn repair_kube_ownership(&self) {
        let user = std::env::var("SUDO_USER")
            .ok()
            .filter(|user| !user.is_empty())
            .or_else(|| std::env::var("USER").ok());
        let Some(user) = user.filter(|user| !user.starts_with('-')) else {
            return;
        };
        let Ok(output) = child("getent", &["passwd", &user], Duration::from_secs(10)).await else {
            return;
        };
        let passwd = String::from_utf8_lossy(&output.stdout);
        let Some(home) = passwd.trim().split(':').nth(5) else {
            return;
        };
        let ownership = format!("{user}:{user}");
        let path = Path::new(home).join(".kube");
        if let Some(path) = path.to_str() {
            let _ = child(
                "sudo",
                &["-n", "chown", "-R", "--", &ownership, path],
                Duration::from_secs(45),
            )
            .await;
        }
    }

    async fn kubectl(&self, arguments: &[&str], budget: Duration) -> Result<(), Failure> {
        child("kubectl", arguments, budget).await.map(|_| ())
    }

    async fn flannel_ready(&self) -> Result<(), Failure> {
        let present = tokio::fs::metadata("/run/flannel/subnet.env")
            .await
            .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0);
        if present {
            Ok(())
        } else {
            Err(Failure::new(9, "flannel subnet file is unavailable"))
        }
    }

    async fn node_ip(&self) -> Result<IpAddr, Failure> {
        let addresses = child("hostname", &["-I"], Duration::from_secs(5)).await?;
        String::from_utf8_lossy(&addresses.stdout)
            .split_whitespace()
            .next()
            .and_then(|address| address.parse().ok())
            .ok_or_else(|| Failure::new(8, "the core node has no usable health address"))
    }

    async fn health(&self, ip: IpAddr, port: u16) -> Result<(), Failure> {
        let endpoint = SocketAddr::new(ip, port);
        let map = |error: &dyn std::error::Error| Failure::new(8, error.to_string());
        let stream = timeout(Duration::from_secs(1), TcpStream::connect(endpoint))
            .await
            .map_err(|error| map(&error))?
            .map_err(|error| map(&error))?;
        let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(stream))
            .await
            .map_err(|error| map(&error))?;
        let mut network = JoinSet::new();
        network.spawn(connection);
        let request = Request::get("/health")
            .header(header::HOST, endpoint.to_string())
            .header(header::CONNECTION, "close")
            .body(Empty::<Bytes>::new())
            .map_err(|error| map(&error))?;
        let response = sender
            .send_request(request)
            .await
            .map_err(|error| map(&error))?;
        if response.status().as_u16() >= 400 {
            return Err(Failure::new(8, format!("HTTP {}", response.status())));
        }
        Limited::new(response.into_body(), 64 * 1024)
            .collect()
            .await
            .map_err(|error| map(error.as_ref()))?;
        Ok(())
    }
}

async fn core_ready(
    cluster: &impl Cluster,
    budget: Duration,
    delay: Duration,
) -> Result<(), Failure> {
    println!("== restart the deployed services onto a known-live state (post-restore boot) ==");
    cluster.repair_kube_ownership().await;

    // Use kubectl's configured identity and endpoint. The readiness probe does
    // not disable TLS verification or choose another cluster.
    poll(budget, delay, |attempt| async move {
        let seconds = attempt.as_secs().max(1);
        let timeout_flag = format!("--request-timeout={seconds}s");
        cluster
            .kubectl(&[&timeout_flag, "get", "--raw=/readyz"], attempt)
            .await
    })
    .await
    .map_err(|error| {
        Failure::new(
            9,
            format!(
                "the apiserver never answered /readyz after the restore: {}",
                error.detail
            ),
        )
    })?;
    poll(budget, delay, |_| cluster.flannel_ready()).await.map_err(|_| {
        Failure::new(9, "flannel never wrote /run/flannel/subnet.env; the pod network cannot place new sandboxes")
    })?;

    let rollout = Duration::from_secs(605);
    cluster
        .kubectl(
            &[
                "-n",
                "kube-system",
                "rollout",
                "restart",
                "deployment/coredns",
            ],
            rollout,
        )
        .await?;
    cluster
        .kubectl(
            &["-n", "amisad", "rollout", "restart", "deployment"],
            rollout,
        )
        .await?;
    cluster
        .kubectl(
            &[
                "-n",
                "kube-system",
                "rollout",
                "status",
                "deployment/coredns",
                "--timeout=600s",
            ],
            rollout,
        )
        .await?;
    for service in SERVICES {
        let target = format!("deployment/{service}");
        cluster
            .kubectl(
                &[
                    "-n",
                    "amisad",
                    "rollout",
                    "status",
                    &target,
                    "--timeout=600s",
                ],
                rollout,
            )
            .await?;
    }

    let ip = cluster.node_ip().await?;
    println!("== wait for the NodePort services to actually answer (post-restore) ==");
    for port in 30080..=30089 {
        poll(budget, delay, |_| cluster.health(ip, port)).await.map_err(|error| Failure::new(8, format!(
            "NodePort {port} never answered - stale amisad-core snapshot? Re-run the deploy chain. {}", error.detail)))?;
    }
    println!("amisad-core is in position: deployments restarted, every NodePort answering.");
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [mode] if mode == "--help" => {
            println!("Usage: amisad-provision <core-ready|edge-report>");
            return ExitCode::SUCCESS;
        }
        [mode] if mode == "core-ready" => core_ready(&LocalCluster, POLL_BUDGET, POLL_DELAY).await,
        [mode] if mode == "edge-report" => edge_report::run().await,
        _ => {
            eprintln!("Usage: amisad-provision <core-ready|edge-report>");
            return ExitCode::FAILURE;
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{}", error.detail);
            ExitCode::from(error.exit)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[derive(Default)]
    struct Fixture {
        trace: RefCell<Vec<String>>,
        rejected: &'static str,
    }

    impl Fixture {
        fn step(&self, event: String) -> Result<(), Failure> {
            let refused = !self.rejected.is_empty() && event.contains(self.rejected);
            self.trace.borrow_mut().push(event);
            if refused {
                Err(Failure::new(17, "fixture refused"))
            } else {
                Ok(())
            }
        }

        async fn run(&self) -> Result<(), Failure> {
            core_ready(self, Duration::from_millis(10), Duration::from_millis(2)).await
        }
    }

    impl Cluster for Fixture {
        async fn repair_kube_ownership(&self) {
            self.step("repair".into()).unwrap();
        }
        async fn kubectl(&self, arguments: &[&str], _: Duration) -> Result<(), Failure> {
            self.step(arguments.join(" "))
        }
        async fn flannel_ready(&self) -> Result<(), Failure> {
            self.step("flannel".into())
        }
        async fn node_ip(&self) -> Result<IpAddr, Failure> {
            self.step("node-ip".into())?;
            Ok(IpAddr::from([127, 0, 0, 1]))
        }
        async fn health(&self, address: IpAddr, port: u16) -> Result<(), Failure> {
            self.step(format!("health {address}:{port}"))
        }
    }

    #[tokio::test]
    async fn requires_every_rollout_and_health_check_in_order() {
        let fixture = Fixture::default();
        fixture.run().await.unwrap();
        let trace = fixture.trace.borrow();
        assert_eq!(
            &trace[..6],
            [
                "repair",
                "--request-timeout=1s get --raw=/readyz",
                "flannel",
                "-n kube-system rollout restart deployment/coredns",
                "-n amisad rollout restart deployment",
                "-n kube-system rollout status deployment/coredns --timeout=600s",
            ]
        );
        for (service, entry) in SERVICES.iter().zip(&trace[6..16]) {
            assert_eq!(
                *entry,
                format!("-n amisad rollout status deployment/{service} --timeout=600s")
            );
        }
        assert_eq!(trace[16], "node-ip");
        assert_eq!(
            &trace[17..],
            (30080..=30089)
                .map(|port| format!("health 127.0.0.1:{port}"))
                .collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn api_and_flannel_failures_leave_deployments_untouched() {
        for rejected in ["--raw=/readyz", "flannel"] {
            let fixture = Fixture {
                rejected,
                ..Default::default()
            };
            assert_eq!(fixture.run().await.unwrap_err().exit, 9);
            assert!(fixture
                .trace
                .borrow()
                .iter()
                .all(|event| !event.contains("rollout")));
        }
    }

    #[tokio::test]
    async fn failed_rollout_preserves_its_exit_and_skips_health_checks() {
        let fixture = Fixture {
            rejected: "status deployment/ledger-svc",
            ..Default::default()
        };
        assert_eq!(fixture.run().await.unwrap_err().exit, 17);
        assert!(fixture
            .trace
            .borrow()
            .iter()
            .all(|event| !event.starts_with("health")));
    }

    #[tokio::test]
    async fn failed_early_nodeport_stops_before_later_ports() {
        let fixture = Fixture {
            rejected: "30082",
            ..Default::default()
        };
        assert_eq!(fixture.run().await.unwrap_err().exit, 8);
        let trace = fixture.trace.borrow();
        assert!(trace.iter().any(|event| event.contains("30081")));
        assert!(trace.iter().all(|event| !event.contains("30083")));
    }
}
