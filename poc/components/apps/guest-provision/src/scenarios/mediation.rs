// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 4283e20e-5347-4d90-b67d-d5b53b4b71e9

use super::{buyer, entries, id, require, Endpoint, REQUEST_BUDGET};
use crate::{child, Failure};
use bytes::Bytes;
use hyper::StatusCode;
use serde_json::{json, Value};
use std::{net::IpAddr, time::Duration};
use tokio::time::sleep;

pub(super) async fn support_request(
    endpoint: &Endpoint,
    route: &str,
    body: Value,
) -> Result<Bytes, Failure> {
    let (status, reply) = endpoint.request(route, Some(body)).await?;
    // A declined request can echo its input. Keep tokens and bodies in the
    // HTTP transaction instead of including them in diagnostics or arguments.
    require(
        status.is_success(),
        &format!("POST {}{route}: HTTP {status}", endpoint.url()),
    )?;
    Ok(reply)
}

pub(super) fn json_reply(bytes: &[u8], label: &str) -> Result<Value, Failure> {
    serde_json::from_slice(bytes)
        .map_err(|error| Failure::new(1, format!("Invalid {label} reply: {error}")))
}

pub(super) async fn sql(query: &str) -> Result<String, Failure> {
    let output = child(
        "sudo",
        &["-u", "postgres", "psql", "-d", "amisad", "-tAc", query],
        REQUEST_BUDGET,
    )
    .await?;
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end_matches(['\r', '\n'])
        .to_owned())
}

const CONSENT_GRANT_COUNT: &str = "SELECT count(*) FROM ledger.consent_ledger WHERE grant_type='disclosure' AND payload::jsonb->>'action' = 'grant'";
const CONSENT_USE_SCOPE: &str = "SELECT payload::jsonb->>'scope' FROM ledger.consent_ledger WHERE grant_type='disclosure' AND payload::jsonb->>'action' = 'use'";
const CONSENT_GRANT: &str = "SELECT payload FROM ledger.consent_ledger WHERE grant_type='disclosure' AND payload::jsonb->>'action' = 'grant'";

pub(crate) async fn run(node: &str, slice_endpoint: &str) -> Result<(), Failure> {
    let ip: IpAddr = node
        .parse()
        .map_err(|_| Failure::new(1, "The core node has no usable IP address"))?;
    Endpoint::parse(slice_endpoint)?;
    let coordinator = Endpoint::node(ip, 30080);
    let ledger = Endpoint::node(ip, 30081);
    let resource = Endpoint::node(ip, 30082);
    let seller = Endpoint::node(ip, 30083);
    let identity = Endpoint::node(ip, 30084);
    let platform = Endpoint::node(ip, 30086);
    let authorized = json_reply(
        &support_request(
            &identity,
            "/v1/tokens",
            json!({"actor":"sam","class":"person"}),
        )
        .await?,
        "support authorization",
    )?;
    let token = authorized["token"]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| Failure::new(1, "No support authorization token was issued"))?;

    println!("== seed a settled order (like s001) to dispute ==");
    resource
        .post(
            "/v1/edges",
            json!({"region":"region-a","endpoint":slice_endpoint}),
        )
        .await?;
    seller
        .post(
            "/v1/offers",
            json!({"offer_id":"serving-set-01","tenant":"elena-atelier",
        "title":"Ceramic serving set","category":"housewares","region":"region-a",
        "price_cents":11000,"deliver_by_days":10,"auto_close":true}),
        )
        .await?;
    let order = json_reply(
        &buyer(&coordinator, &identity, &["submit"]).await?,
        "ordered match",
    )?;
    let match_id = id(&order, "match_id")?;
    let environment = id(&order, "environment_id")?;
    for state in ["provisioning", "fulfilled"] {
        seller
            .post(
                "/v1/orders/advance",
                json!({"match_id":match_id,"state":state}),
            )
            .await?;
    }

    println!("== Maya reports non-delivery -> a support case opens with METADATA ONLY ==");
    let settlement = format!("/v1/settlements/match/{match_id}");
    ledger.get(&settlement).await?;
    let case = json_reply(&support_request(&platform, "/v1/support/cases",
        json!({"token":token,"match_id":match_id,
            "metadata":{"order_state":"settled","carrier_confirmation":"delivered","value_cents":11000}})).await?, "support case")?;
    let case_id = id(&case, "case_id")?;
    println!("support case: {case_id}");
    let record = platform
        .get(&format!("/v1/support/cases/{case_id}"))
        .await?;
    let published = record.to_string().to_ascii_lowercase();
    for marker in [
        "maya",
        "wedding gift",
        "budget_cents",
        "deadline_days",
        "envelope",
        "token",
    ] {
        require(
            !published.contains(marker),
            &format!("support case leaked: {marker}"),
        )?;
    }
    println!("ASSERT case carries metadata only, no buyer identity OK");

    println!("== Sam requests, Maya grants a scoped time-boxed disclosure ==");
    support_request(
        &platform,
        "/v1/support/cases/disclosure/request",
        json!({"token":token,"case_id":case_id}),
    )
    .await?;
    let grant = json_reply(
        &buyer(
            &coordinator,
            &identity,
            &["disclose", case_id, "delivery-photo-ref-77", "10"],
        )
        .await?,
        "disclosure grant",
    )?;
    require(
        grant["scope"] == case_id && grant["expiry_ts"].as_u64().is_some_and(|expiry| expiry > 0),
        "The grant has the wrong case scope or no expiry",
    )?;
    println!("ASSERT disclosure granted, scoped to the case OK");

    let disclosure = format!("/v1/support/cases/{case_id}/disclosure");
    let artifact = platform.get(&disclosure).await?;
    require(
        artifact["artifact"] == "delivery-photo-ref-77",
        "The granted artifact is unavailable",
    )?;
    println!("ASSERT artifact accessible while granted OK");

    let count = sql(CONSENT_GRANT_COUNT).await?;
    if count != "1" {
        return Err(Failure::new(
            9,
            format!("expected 1 disclosure grant row, got {count}"),
        ));
    }
    let used = sql(CONSENT_USE_SCOPE).await?;
    if used != case_id {
        return Err(Failure::new(
            9,
            format!("expected one disclosure use scoped to {case_id}, got '{used}'"),
        ));
    }
    let grant = json_reply(sql(CONSENT_GRANT).await?.as_bytes(), "consent ledger grant")?;
    require(
        grant["scope"] == case_id
            && grant["action"] == "grant"
            && grant["expiry_ts"]
                .as_u64()
                .zip(grant["ts"].as_u64())
                .is_some_and(|(expiry, time)| expiry > time),
        "The consent ledger lost disclosure scope or expiry",
    )?;
    println!("ASSERT disclosure grant scoped + time-boxed on the consent ledger OK");

    println!("== refund posts as compensating entries; original history untouched ==");
    let adjusted = json_reply(
        &support_request(
            &platform,
            "/v1/support/cases/refund",
            json!({"token":token,"case_id":case_id}),
        )
        .await?,
        "refund",
    )?;
    require(
        adjusted["adjustment_entries"] == 4,
        "The refund did not produce four compensating entries",
    )?;
    println!("ASSERT compensating entries posted OK");

    let refunded = ledger.get(&settlement).await?;
    let (adjustments, originals): (Vec<_>, Vec<_>) = entries(&refunded)?
        .iter()
        .partition(|entry| entry["entry_type"] == "adjustment");
    let original_value = originals.iter().try_fold(0_i64, |sum, entry| {
        sum.checked_add(entry["amount_cents"].as_i64()?)
    });
    require(
        originals.len() == 4
            && adjustments.len() == 4
            && adjustments.iter().all(|entry| entry["case_id"] == case_id)
            && original_value == Some(11000)
            && refunded["total_cents"] == 0
            && refunded["value_cents"] == 11000,
        "The refund lost original entries, case linkage, or cumulative value",
    )?;
    println!("ASSERT refund as compensating entries, original untouched OK");

    println!("== Sam resolves; recurring-pattern escalates to Priya ==");
    support_request(
        &platform,
        "/v1/support/cases/resolve",
        json!({"token":token,"case_id":case_id}),
    )
    .await?;
    let incident = platform
        .post_json(
            "/v1/incidents",
            json!({"summary":"recurring non-delivery pattern",
        "from":"support-desk","environment_ids":[environment]}),
        )
        .await?;
    id(&incident, "case_id")?;
    println!("ASSERT recurring-pattern escalation OK");

    println!("== TVP: the disclosure grant expires -> the access path is gone ==");
    sleep(Duration::from_secs(14)).await;
    let (status, _) = platform.request(&disclosure, None).await?;
    if status != StatusCode::GONE {
        return Err(Failure::new(
            9,
            format!(
                "disclosed artifact still accessible after expiry (got {})",
                status.as_u16()
            ),
        ));
    }
    println!("ASSERT post-expiry access fails OK");

    let proof = ledger.get("/v1/verify").await?;
    require(
        ["attestation_ok", "settlement_ok", "consent_ok"]
            .iter()
            .all(|key| proof[*key].as_bool() == Some(true)),
        "A ledger chain failed after the refund or disclosure",
    )?;
    println!("ASSERT all chains verify OK");
    println!("s008.mediation HAPPY PATH PASSED");
    Ok(())
}
