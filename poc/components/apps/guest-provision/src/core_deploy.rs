// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 426cd6d0-1070-4fe5-9889-5bbc846b8d98

use crate::{
    child, child_with_input, poll, Cluster, Failure, LocalCluster, Workspace, POLL_BUDGET,
    POLL_DELAY, SERVICES,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::json;
use std::{env, fs, io, path::Path, process::Stdio, time::Duration};
use tokio::{io::AsyncWriteExt, process::Command, time::timeout};

const TOOL: Duration = Duration::from_secs(30);
const BUILD: Duration = Duration::from_secs(1200);
const ROLLOUT: Duration = Duration::from_secs(615);
const DATABASE_URL: &str = "postgres://amisad:$(AMISAD_DB_PASSWORD)@$(NODE_IP):5432/amisad";
const PORTS: [(&str, u16); 10] = [
    ("fabric-coordinator", 30080),
    ("ledger-svc", 30081),
    ("resource-svc", 30082),
    ("seller-svc", 30083),
    ("identity-mock", 30084),
    ("insights-svc", 30085),
    ("platform-svc", 30086),
    ("ads-svc", 30087),
    ("connect-svc", 30088),
    ("audit-svc", 30089),
];

async fn confidential(program: &str, arguments: &[&str], input: &[u8]) -> bool {
    let run = async {
        let mut process = Command::new(program)
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        process
            .stdin
            .take()
            .ok_or(io::ErrorKind::BrokenPipe)?
            .write_all(input)
            .await?;
        process.wait().await
    };
    matches!(timeout(TOOL, run).await, Ok(Ok(status)) if status.success())
}

async fn random_hex(length: usize) -> Result<String, Failure> {
    let length_arg = length.to_string();
    let run = Command::new("openssl")
        .args(["rand", "-hex", &length_arg])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    if let Ok(Ok(output)) = timeout(TOOL, run).await {
        if output.status.success() {
            if let Ok(value) = std::str::from_utf8(&output.stdout) {
                let value = value.trim_end_matches(['\r', '\n']);
                if value.len() == length * 2
                    && value
                        .bytes()
                        .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
                {
                    return Ok(value.to_owned());
                }
            }
        }
    }
    Err(Failure::new(
        1,
        "OpenSSL did not supply the expected number of random bytes",
    ))
}

async fn replace_secret(name: &str, key: &str, secret: &str) -> Result<(), Failure> {
    child(
        "kubectl",
        &[
            "-n",
            "amisad",
            "delete",
            "secret",
            name,
            "--ignore-not-found",
        ],
        TOOL,
    )
    .await?;
    let encoded = STANDARD.encode(secret);
    let manifest =
        json!({"apiVersion":"v1", "kind":"Secret", "metadata":{"name":name,"namespace":"amisad"},
        "type":"Opaque", "data":{(key):encoded}})
        .to_string();
    if confidential("kubectl", &["create", "-f", "-"], manifest.as_bytes()).await {
        Ok(())
    } else {
        Err(Failure::new(
            1,
            format!("Could not create Secret amisad/{name}"),
        ))
    }
}

async fn deploy_secrets(budget: Duration, delay: Duration) -> Result<(), Failure> {
    let api = poll(budget, delay, |remaining| async move {
        child(
            "kubectl",
            &["--request-timeout=2s", "get", "--raw=/readyz"],
            remaining,
        )
        .await
        .map(|_| ())
    });
    let database = poll(budget, delay, |remaining| async move {
        child("sudo", &["-u", "postgres", "pg_isready", "-q"], remaining)
            .await
            .map(|_| ())
    });
    let (api, database) = tokio::join!(api, database);
    if api.is_err() || database.is_err() {
        let mut sources = Vec::new();
        if api.is_err() {
            sources.push("Kubernetes API");
        }
        if database.is_err() {
            sources.push("PostgreSQL");
        }
        return Err(Failure::new(
            1,
            format!(
                "{} readiness did not confirm within {}s. The role password was left intact.",
                sources.join(" and "),
                budget.as_secs()
            ),
        ));
    }
    let password = random_hex(24).await?;
    if child("kubectl", &["get", "namespace", "amisad"], TOOL)
        .await
        .is_err()
    {
        child("kubectl", &["create", "namespace", "amisad"], TOOL).await?;
    }
    let sql = format!("SET log_statement = 'none';\nSET log_min_duration_statement = -1;\nSET log_min_error_statement = 'panic';\nALTER ROLE amisad LOGIN PASSWORD '{password}';\n");
    if !confidential(
        "sudo",
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
        sql.as_bytes(),
    )
    .await
    {
        return Err(Failure::new(1, "Could not set the amisad role password"));
    }
    replace_secret("amisad-database", "password", &password).await.map_err(|error| Failure::new(error.exit, format!(
        "{}. The role password changed. Rerun this step to rotate it and recreate Secret amisad/amisad-database.", error.detail)))?;
    println!("  amisad role password set for this build; published only as Secret amisad/amisad-database");
    let token = random_hex(32).await?;
    replace_secret("amisad-ledger-write", "token", &token).await?;
    println!("  ledger write token made for this build; published only as Secret amisad/amisad-ledger-write");
    Ok(())
}

async fn import_images(tags: &[String]) -> Result<(), Failure> {
    let io_error = |error: io::Error| {
        Failure::new(1, format!("Could not stream images to containerd: {error}"))
    };
    let mut docker = Command::new("docker")
        .arg("save")
        .args(tags)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(io_error)?;
    let images = docker
        .stdout
        .take()
        .ok_or_else(|| io_error(io::ErrorKind::BrokenPipe.into()))?;
    let input: Stdio = images.try_into().map_err(io_error)?;
    let load = child_with_input(
        "sudo",
        &["ctr", "-n", "k8s.io", "images", "import", "-"],
        BUILD,
        input,
    );
    let (save, load) = tokio::join!(timeout(BUILD, docker.wait()), load);
    load?;
    match save {
        Ok(Ok(status)) if status.success() => Ok(()),
        _ => Err(Failure::new(
            1,
            "docker save did not complete the container image stream",
        )),
    }
}

async fn build_images() -> Result<(), Failure> {
    let staging = Workspace::create(&env::temp_dir(), "amisad-build-context").await?;
    let io_error =
        |error: io::Error| Failure::new(1, format!("Could not stage an image context: {error}"));
    let mut tags = Vec::new();
    for service in SERVICES {
        let dir = staging.0.join(service);
        fs::create_dir(&dir).map_err(io_error)?;
        fs::copy(Path::new("target/release").join(service), dir.join(service)).map_err(io_error)?;
        let dockerfile = format!("FROM gcr.io/distroless/cc-debian12\nCOPY {service} /usr/local/bin/{service}\nENV PORT=8080\nEXPOSE 8080\nENTRYPOINT [\"/usr/local/bin/{service}\"]\n");
        fs::write(dir.join("Dockerfile"), dockerfile).map_err(io_error)?;
        let tag = format!("amisad/{service}:poc");
        let path = dir
            .to_str()
            .ok_or_else(|| Failure::new(1, "Invalid image context path"))?;
        let output = child("docker", &["build", "-t", &tag, path], BUILD).await?;
        print!("{}", String::from_utf8_lossy(&output.stdout));
        tags.push(tag);
        fs::remove_dir_all(dir).map_err(io_error)?;
    }
    import_images(&tags).await
}

async fn publish_charts() -> Result<(), Failure> {
    for service in SERVICES {
        let path = format!("workloads/services/{service}");
        let image = format!("image=amisad/{service}:poc");
        let database = format!("databaseUrl={DATABASE_URL}");
        let mut arguments = vec![
            "upgrade",
            "--install",
            service,
            &path,
            "--namespace",
            "amisad",
            "--create-namespace",
            "--set",
            &image,
            "--set",
            "pullPolicy=Never",
        ];
        if matches!(service, "ledger-svc" | "seller-svc" | "resource-svc") {
            arguments.extend([
                "--set-string",
                &database,
                "--set-string",
                "databasePasswordSecret=amisad-database",
            ]);
        }
        if matches!(
            service,
            "ledger-svc" | "seller-svc" | "fabric-coordinator" | "platform-svc"
        ) {
            arguments.extend(["--set-string", "ledgerWriteSecret=amisad-ledger-write"]);
        }
        let output = child("helm", &arguments, ROLLOUT).await?;
        print!("{}", String::from_utf8_lossy(&output.stdout));
    }
    Ok(())
}

async fn wait_for_services() -> Result<(), Failure> {
    for service in SERVICES {
        let deployment = format!("deployment/{service}");
        let result = child(
            "kubectl",
            &[
                "-n",
                "amisad",
                "wait",
                "--for=condition=available",
                &deployment,
                "--timeout=600s",
            ],
            ROLLOUT,
        )
        .await;
        if let Err(error) = result {
            eprintln!("== {service} never became available; cluster state ==");
            let selector = format!("app={service}");
            let diagnostics: [&[&str]; 6] = [
                &["get", "pods", "-o", "wide"],
                &["describe", &deployment],
                &["get", "pods", "-l", &selector, "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\t\"}{.status.phase}{\"\t\"}{range .status.containerStatuses[*]}{.state}{.lastState}{end}{\"\n\"}{end}"],
                &["logs", &deployment, "--all-containers", "--tail=40"],
                &["logs", &deployment, "--all-containers", "--previous", "--tail=40"],
                &["get", "events", "--sort-by=.lastTimestamp"],
            ];
            for arguments in diagnostics {
                let mut command = vec!["-n", "amisad"];
                command.extend(arguments);
                if let Ok(output) = child("kubectl", &command, TOOL).await {
                    for line in String::from_utf8_lossy(&output.stdout)
                        .lines()
                        .rev()
                        .take(40)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                    {
                        eprintln!("{line}");
                    }
                }
            }
            return Err(error);
        }
    }
    Ok(())
}

pub(super) async fn run() -> Result<(), Failure> {
    println!("== build thin images + deploy 10 services ==");
    LocalCluster.repair_kube_ownership().await;
    deploy_secrets(POLL_BUDGET, POLL_DELAY).await?;
    build_images().await?;
    publish_charts().await?;
    wait_for_services().await?;
    println!("== expose NodePorts for host/edge access ==");
    for (service, port) in PORTS {
        let patch = json!({"spec":{"type":"NodePort","ports":[{"port":8080,"targetPort":8080,"nodePort":port}]}}).to_string();
        child(
            "kubectl",
            &["-n", "amisad", "patch", "svc", service, "-p", &patch],
            TOOL,
        )
        .await?;
    }
    println!("amisad-core DEPLOY PASSED");
    Ok(())
}

fn registry_binding(output: &[u8]) -> Result<(String, bool), Failure> {
    let invalid = || {
        Failure::new(
            1,
            "Docker returned an unreadable registry container definition",
        )
    };
    let response: serde_json::Value = serde_json::from_slice(output).map_err(|_| invalid())?;
    let id = response["Id"]
        .as_str()
        .filter(|value| {
            value.len() == 64
                && value
                    .bytes()
                    .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        })
        .ok_or_else(invalid)?;
    let loopback = response
        .pointer("/HostConfig/PortBindings/5000~1tcp")
        .and_then(serde_json::Value::as_array)
        .is_some_and(|ports| ports.len() == 1 && ports[0]["HostIp"].as_str() == Some("127.0.0.1"));
    Ok((id.to_owned(), loopback))
}

async fn start_local_registry() -> Result<(), Failure> {
    if let Ok(result) = child(
        "docker",
        &["container", "inspect", "--format", "{{json .}}", "registry"],
        TOOL,
    )
    .await
    {
        let (id, loopback) = registry_binding(&result.stdout)?;
        if loopback {
            return child("docker", &["start", &id], TOOL).await.map(|_| ());
        }
        println!("Re-creating the registry container to publish port 5000 on 127.0.0.1 only");
        child("docker", &["rm", "-f", &id], TOOL).await?;
    }
    child(
        "docker",
        &[
            "run",
            "-d",
            "-p",
            "127.0.0.1:5000:5000",
            "--restart=always",
            "--name",
            "registry",
            "registry:2.8.3",
        ],
        BUILD,
    )
    .await?;
    Ok(())
}

pub(super) async fn deploy_skeletons() -> Result<(), Failure> {
    let uid = crate::core_users::login_uid()?;
    let home = crate::core_users::login_home(uid).await?;
    let poc = home.join("git/yuruna/project/poc");
    env::set_current_dir(&poc).map_err(|error| {
        Failure::new(
            1,
            format!("Open AmisAd project at {}: {error}", poc.display()),
        )
    })?;
    LocalCluster.repair_kube_ownership().await;
    start_local_registry().await?;
    for service in SERVICES {
        let image = format!("localhost:5000/amisad/{service}:latest");
        let dockerfile = format!("components/services/{service}/Dockerfile");
        let chart = format!("workloads/services/{service}");
        child(
            "docker",
            &["build", "-f", &dockerfile, "-t", &image, "."],
            BUILD,
        )
        .await?;
        child("docker", &["push", &image], BUILD).await?;
        child(
            "helm",
            &[
                "upgrade",
                "--install",
                service,
                &chart,
                "--namespace",
                "amisad",
                "--create-namespace",
                "--set",
                &format!("image={image}"),
            ],
            TOOL,
        )
        .await?;
    }
    let deployments = child("kubectl", &["-n", "amisad", "get", "deployments"], TOOL).await?;
    print!("{}", String::from_utf8_lossy(&deployments.stdout));
    println!("AmisAd POC skeletons deployed");
    Ok(())
}

#[cfg(test)]
mod registry_tests {
    use super::*;

    #[test]
    fn requires_a_precise_container_identity_for_any_registry_action() {
        let id = "a".repeat(64);
        let registry = |address: &str| {
            json!({"Id":id,"HostConfig":{"PortBindings":{"5000/tcp":[{"HostIp":address}]}}})
                .to_string()
        };
        assert_eq!(
            registry_binding(registry("127.0.0.1").as_bytes()).unwrap(),
            (id.clone(), true)
        );
        assert_eq!(
            registry_binding(registry("0.0.0.0").as_bytes()).unwrap(),
            (id, false)
        );
        assert!(registry_binding(br#"{"Id":"registry"}"#).is_err());
    }
}
