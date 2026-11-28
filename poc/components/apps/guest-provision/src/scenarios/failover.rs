// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42b6d2de-c3d8-4e75-90aa-6a7e9f881264

use super::{
    buyer, entries, id,
    mediation::{json_reply, sql},
    require, verify_ledger, Endpoint,
};
use crate::Failure;
use serde_json::{json, Value};
use std::net::IpAddr;

async fn lifecycle(ledger: &Endpoint, env: &str, outcome: &str) -> Result<Value, Failure> {
    let report = ledger.get(&format!("/v1/attestations/env/{env}")).await?;
    require(
        entries(&report)?
            .iter()
            .map(|row| row["lifecycle"].as_str().unwrap_or(""))
            .eq(["created", "attested", outcome, "destroyed"]),
        "The edge lifecycle does not have exactly the expected ordered states",
    )?;
    Ok(report)
}

pub(crate) async fn run(node: &str, edge_a: &str, edge_b: &str) -> Result<(), Failure> {
    let ip: IpAddr = node
        .parse()
        .map_err(|_| Failure::new(1, "The core node has no usable IP address"))?;
    let a = Endpoint::parse(edge_a)?;
    Endpoint::parse(edge_b)?;
    let coordinator = Endpoint::node(ip, 30080);
    let ledger = Endpoint::node(ip, 30081);
    let resource = Endpoint::node(ip, 30082);
    let seller = Endpoint::node(ip, 30083);
    let identity = Endpoint::node(ip, 30084);
    let platform = Endpoint::node(ip, 30086);

    println!("== Tom: allocation policy - two regions, region-b roomier, region-a sovereign ==");
    for (region, edge, capacity) in [("region-a", edge_a, 2), ("region-b", edge_b, 10)] {
        resource
            .post(
                "/v1/edges",
                json!({"region":region,"endpoint":edge,"capacity":capacity}),
            )
            .await?;
    }
    resource
        .post(
            "/v1/policies",
            json!({"jurisdiction":"region-a","regions":["region-a"]}),
        )
        .await?;
    let default = resource
        .post_json(
            "/v1/placements",
            json!({"jurisdiction":"region-unrestricted"}),
        )
        .await?;
    require(
        default["region"] == "region-b",
        "Default placement did not choose the higher capacity region",
    )?;
    println!("ASSERT capacity-greedy default picks region-b OK");
    let restricted = resource
        .post_json("/v1/placements", json!({"jurisdiction":"region-a"}))
        .await?;
    require(
        restricted["region"] == "region-a",
        "Sovereignty did not pin placement to region-a",
    )?;
    println!("ASSERT jurisdiction policy pins region-a OK");

    seller.post("/v1/offers", json!({"offer_id":"serving-set-01","tenant":"elena-atelier",
        "title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,
        "deliver_by_days":10,"auto_close":true})).await?;
    let faults = a
        .post_json("/v1/faults", json!({"mode":"isolation","count":2}))
        .await?;
    require(faults["armed"] == 2, "Both isolation faults were not armed")?;
    println!("ASSERT faults armed OK");

    println!("== the match: abort, abort (systemic), then a clean completion ==");
    let completed = json_reply(
        &buyer(&coordinator, &identity, &["submit"]).await?,
        "completed match",
    )?;
    let match_id = id(&completed, "match_id")?;
    let completed_env = id(&completed, "environment_id")?;
    println!("completed match {match_id} in environment {completed_env}");

    let incidents = resource.get("/v1/incidents").await?;
    let rows = incidents["incidents"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "No edge incidents were returned"))?;
    require(
        rows.len() == 2
            && rows.iter().all(|incident| {
                incident["event"] == "aborted"
                    && incident["fault"] == "isolation"
                    && incident["region"] == "region-a"
            }),
        "The incident queue lacks both isolated region-a aborts",
    )?;
    let aborted = [
        id(&rows[0], "environment_id")?,
        id(&rows[1], "environment_id")?,
    ];
    println!("ASSERT two isolation incidents queued OK");

    for env in aborted {
        let aborted_lifecycle = lifecycle(&ledger, env, "aborted").await?;
        require(
            entries(&aborted_lifecycle)?[2]["fault"] == "isolation",
            "The aborted lifecycle lost its isolation reason",
        )?;
        let public = aborted_lifecycle["entries"]
            .to_string()
            .to_ascii_lowercase();
        for marker in [
            "maya",
            "budget_cents",
            "deadline_days",
            "context",
            "envelope",
            "wish list",
        ] {
            require(
                !public.contains(marker),
                &format!("aborted environment leaked: {marker}"),
            )?;
        }
        println!("ASSERT aborted lifecycle + zero egress OK");
    }
    lifecycle(&ledger, completed_env, "executed").await?;
    println!("ASSERT completed lifecycle OK");

    let report = ledger.get("/v1/attestations").await?;
    let all = entries(&report)?;
    require(
        all.len() == 12 && all.iter().all(|row| row["payload"]["region"] == "region-a"),
        "The attestation corpus does not contain only the twelve region-a lifecycle events",
    )?;
    println!("ASSERT every allocation stayed in the compliant region OK");

    for state in ["provisioning", "fulfilled"] {
        seller
            .post(
                "/v1/orders/advance",
                json!({"match_id":match_id,"state":state}),
            )
            .await?;
    }
    let proof = ledger.get("/v1/verify").await?;
    verify_ledger(&proof, false)?;
    require(
        proof["settlement_len"] == 4,
        "There is more or less than one four-way settlement",
    )?;
    println!("ASSERT exactly one settlement OK");
    let settled = ledger
        .get(&format!("/v1/settlements/match/{match_id}"))
        .await?;
    require(
        settled["confirmed"].as_bool() == Some(true)
            && settled["total_cents"] == 11000
            && settled["value_cents"] == 11000
            && entries(&settled)?
                .iter()
                .filter(|row| row["party"] == "network")
                .count()
                == 1,
        "The completed match does not have exactly one hosting credit",
    )?;
    println!("ASSERT hosting revenue for the completed match only OK");

    let escalated = platform
        .post_json(
            "/v1/incidents",
            json!({"summary":"systemic isolation faults in region-a",
        "from":"resource-ops","environment_ids":aborted}),
        )
        .await?;
    let case_id = id(&escalated, "case_id")?;
    let case = platform.get(&format!("/v1/incidents/{case_id}")).await?;
    require(
        case["environment_ids"] == json!(aborted) && case["status"] == "open",
        "The platform case is not open for both aborted environments",
    )?;
    println!("ASSERT platform case references both aborted lifecycles OK");

    let rows = sql("SELECT count(*) FROM ledger.attestation_ledger").await?;
    if rows != "12" {
        return Err(Failure::new(
            9,
            format!("attestation rows not persisted as expected (rows: {rows})"),
        ));
    }
    println!("ASSERT PostgreSQL attestation write-through OK");
    println!("s004.failover HAPPY PATH PASSED");
    Ok(())
}
