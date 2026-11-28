// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42c26efe-ec13-40c3-8c26-f329d8e0aad1

use crate::{edge_report, scenarios, slice_delivery, Cluster, Failure, LocalCluster};
use std::{
    env,
    net::{IpAddr, SocketAddr},
};

async fn status_service() -> Option<SocketAddr> {
    if let Some(address) = env::var("YURUNA_STATUS_SERVICE_IP")
        .ok()
        .zip(env::var("YURUNA_STATUS_SERVICE_PORT").ok())
        .and_then(|(ip, port)| Some(SocketAddr::new(ip.parse().ok()?, port.parse().ok()?)))
        .filter(|address| address.port() != 0)
    {
        return Some(address);
    }
    tokio::fs::read_to_string("/etc/yuruna/host.env")
        .await
        .ok()
        .and_then(|text| edge_report::endpoint(&text))
}

async fn start_slice(node: IpAddr, region: &str) -> Result<String, Failure> {
    let mut target = env::var("EDGE_HOST").unwrap_or_default();
    if target.is_empty() {
        if let Some(status) = status_service().await {
            if let Some(edge) = edge_report::resolve(
                "amisad-edge-a",
                &status.ip().to_string(),
                &status.port().to_string(),
            )
            .await?
            {
                target = format!("amisad-edge-a-admin@{edge}");
            }
        }
    }
    println!("== slice-runtime (edge amisad-edge-a) ==");
    let result = slice_delivery::start_scenario(
        &target,
        region,
        &format!("http://{}", SocketAddr::new(node, 30081)),
        &format!("http://{}", SocketAddr::new(node, 30082)),
        &env::var("AMISAD_ALLOW_SINGLE_VM").unwrap_or_default(),
    )
    .await?;
    println!("slice-runtime at {result}");
    Ok(result)
}

pub(super) async fn run(name: &str) -> Result<(), Failure> {
    let node = LocalCluster.node_ip().await?;
    let address = node.to_string();
    match name {
        "fulfillment" => scenarios::fulfillment(&address, &start_slice(node, "").await?).await,
        "fitting" => scenarios::fitting(&address, &start_slice(node, "").await?).await,
        "silence" => scenarios::silence::run(&address, &start_slice(node, "").await?).await,
        "failover" => {
            println!("== slice-runtime on BOTH edges (region identity attested) ==");
            let status = status_service()
                .await
                .ok_or_else(|| Failure::new(2, "no host.env - cannot resolve the edges"))?;
            slice_delivery::failover(
                &address,
                &status.ip().to_string(),
                &status.port().to_string(),
            )
            .await
        }
        "attribution" => scenarios::attribution::run(&address, &start_slice(node, "").await?).await,
        "mandate" => scenarios::mandate::run(&address, &start_slice(node, "").await?).await,
        "inventory" => scenarios::inventory::run(&address, &start_slice(node, "").await?).await,
        "mediation" => scenarios::mediation::run(&address, &start_slice(node, "").await?).await,
        "suppression" => scenarios::suppression(&address).await,
        "certification" => {
            scenarios::certification::run(&address, &start_slice(node, "region-a").await?).await
        }
        _ => Err(Failure::new(2, "Unknown AmisAd scenario")),
    }
}
