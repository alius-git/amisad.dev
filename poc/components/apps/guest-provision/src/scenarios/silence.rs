// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42cb9307-3290-46c9-8251-f2596eb03ca3

use super::{
    buyer, entries, id,
    mandate::refused,
    mediation::{json_reply, sql},
    require, Endpoint,
};
use crate::{poll, Failure};
use serde_json::{json, Value};
use std::{net::IpAddr, time::Duration};

const ATTEST_ROWS: &str = "SELECT count(*) FROM ledger.attestation_ledger";

async fn contributions(insights: &Endpoint, expected: u64) -> Result<(), Failure> {
    let cycle = insights
        .post_json("/v1/aggregation/cycle", Value::Null)
        .await?;
    require(
        cycle["contributions"].as_u64() == Some(expected),
        &format!("The aggregation cycle did not include {expected} contributions"),
    )
}

fn check_history(consents: &Value) -> Result<u64, Failure> {
    let history = consents["history"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "The buyer has no consent history"))?;
    require(
        consents["contribution"] == "granted"
            && consents["participation"] == "granted"
            && !consents.to_string().to_ascii_lowercase().contains("maya"),
        "The consent record is not fully granted and pseudonymous",
    )?;
    let history_without_uses =
        history
            .iter()
            .filter(|entry| entry["action"] != "use")
            .map(|entry| {
                (
                    entry["grant_type"].as_str().unwrap_or(""),
                    entry["action"].as_str().unwrap_or(""),
                )
            });
    require(
        history_without_uses.eq([
            ("contribution", "grant"),
            ("participation", "grant"),
            ("participation", "revoke"),
            ("contribution", "revoke"),
            ("contribution", "grant"),
            ("participation", "grant"),
        ]),
        "The consent chain does not preserve the grant, revocation, and resumption history",
    )?;
    let mut revoked = false;
    let mut uses = 0;
    for entry in history
        .iter()
        .filter(|entry| entry["grant_type"] == "participation")
    {
        match entry["action"].as_str() {
            Some("grant") => revoked = false,
            Some("revoke") => revoked = true,
            Some("use") => {
                require(
                    !revoked
                        && entry["match_id"]
                            .as_str()
                            .is_some_and(|matched| !matched.is_empty()),
                    "A participation use has no match or falls in the revocation window",
                )?;
                uses += 1;
            }
            _ => {}
        }
    }
    require(uses > 0, "The consent history has no participation use")?;
    Ok(uses)
}

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
    let insights = Endpoint::node(ip, 30085);

    println!("== seed: edge, Elena's catalog, Maya's signup consents ==");
    resource
        .post(
            "/v1/edges",
            json!({"region":"region-a","endpoint":slice_endpoint}),
        )
        .await?;
    for (offer, title, price, days) in [
        ("serving-set-01", "Ceramic serving set", 11000, 10),
        ("crystal-vase-02", "Crystal vase", 15000, 5),
    ] {
        seller.post("/v1/offers", json!({"offer_id":offer,"tenant":"elena-atelier","title":title,
            "category":"housewares","region":"region-a","price_cents":price,"deliver_by_days":days,"auto_close":true})).await?;
    }

    buyer(&coordinator, &identity, &["resume"]).await?;
    let matched = json_reply(
        &buyer(&coordinator, &identity, &["submit"]).await?,
        "in-flight match",
    )?;
    let match_id = id(&matched, "match_id")?;
    println!("in-flight match: {match_id}");
    let dress = json_reply(
        &buyer(&coordinator, &identity, &["open", "dress"]).await?,
        "open dress need",
    )?;
    let dress_handle = id(&dress, "handle")?;
    require(dress["status"] == "open", "The dress need was not open")?;
    println!("ASSERT dress need open OK");
    let decanter = json_reply(
        &buyer(&coordinator, &identity, &["open", "decanter"]).await?,
        "open decanter need",
    )?;
    require(
        decanter["status"] == "open",
        "The decanter need was not open",
    )?;
    println!("ASSERT decanter need open OK");
    contributions(&insights, 2).await?;
    println!("ASSERT baseline contributions == 2 OK");

    println!("== Maya pauses participation (revocation on the consent ledger) ==");
    buyer(&coordinator, &identity, &["pause"]).await?;
    let paused = sql(ATTEST_ROWS).await?;
    println!("attestation rows at pause: {paused}");
    seller.post("/v1/offers", json!({"offer_id":"linen-wrap-09","tenant":"brisa-outlet","title":"Linen wrap dress",
        "category":"dresses","region":"region-a","price_cents":13000,"deliver_by_days":2,"auto_close":true,
        "attributes":["midi","sleeves","warm-fabric"]})).await?;
    // Allow the detached offer-published event to finish before checking
    // whether the paused buyer received a notification.
    tokio::time::sleep(Duration::from_secs(5)).await;
    let notifications = format!("/v1/notifications/{dress_handle}");
    require(
        coordinator.get(&notifications).await?["notifications"]
            .as_array()
            .is_some_and(Vec::is_empty),
        "The paused buyer received a notification",
    )?;
    println!("ASSERT zero notifications while paused OK");
    require(
        seller.get("/v1/orders").await?["count"] == 1,
        "The paused buyer's order count changed",
    )?;
    println!("ASSERT no new order while paused OK");
    require(
        coordinator
            .post_json("/v1/offers/published", Value::Null)
            .await?["rematched"]
            == 0,
        "The explicit published-offer cycle matched a paused buyer",
    )?;
    println!("ASSERT explicit cycle rematched nothing while paused OK");
    refused(&coordinator, &identity, &["open", "decanter"], "(403)").await?;
    println!("ASSERT refusal while paused OK");

    for state in ["provisioning", "fulfilled"] {
        seller
            .post(
                "/v1/orders/advance",
                json!({"match_id":match_id,"state":state}),
            )
            .await?;
    }
    let settled = ledger
        .get(&format!("/v1/settlements/match/{match_id}"))
        .await?;
    require(
        settled["confirmed"].as_bool() == Some(true)
            && settled["total_cents"] == 11000
            && settled["value_cents"] == 11000,
        "The pre-revocation commitment did not settle normally",
    )?;
    println!("ASSERT in-flight order settled normally OK");

    buyer(&coordinator, &identity, &["withdraw"]).await?;
    contributions(&insights, 0).await?;
    println!("ASSERT zero contributions after withdrawal OK");
    let before_resume = sql(ATTEST_ROWS).await?;
    if before_resume != paused {
        return Err(Failure::new(
            9,
            format!("environments were created while paused: {paused} -> {before_resume}"),
        ));
    }
    println!("ASSERT zero environments while paused OK");

    println!("== Maya resumes: the open needs are served again immediately ==");
    let resumed = buyer(&coordinator, &identity, &["resume"]).await?;
    let last = String::from_utf8_lossy(&resumed);
    let cycle = json_reply(last.lines().last().unwrap_or("").as_bytes(), "resume cycle")?;
    require(
        cycle["rematched"] == 1,
        "Only the dress need should match on resumption",
    )?;
    println!("ASSERT resumption rematched the dress need OK");
    let notice = coordinator.get(&notifications).await?;
    require(
        notice["notifications"]
            .as_array()
            .is_some_and(|rows| matches!(rows.as_slice(), [entry] if entry["kind"] == "match")),
        "The buyer did not receive exactly one resumption notification",
    )?;
    println!("ASSERT match notification after resume OK");
    let orders = seller.get("/v1/orders").await?;
    let listed = orders["orders"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "There are no orders after resumption"))?;
    let mut dress_orders = listed
        .iter()
        .filter(|row| row["offer_id"] == "linen-wrap-09");
    require(
        orders["count"] == 2
            && dress_orders
                .next()
                .is_some_and(|row| row["state"] == "committed")
            && dress_orders.next().is_none(),
        "The dress order was missing, duplicated, or uncommitted",
    )?;
    println!("ASSERT dress order committed after resume OK");
    contributions(&insights, 1).await?;
    println!("ASSERT decanter need contributes again OK");

    let final_rows = sql(ATTEST_ROWS)
        .await?
        .parse::<u64>()
        .map_err(|_| Failure::new(1, "PostgreSQL returned an invalid attestation count"))?;
    require(
        before_resume
            .parse::<u64>()
            .ok()
            .and_then(|before| before.checked_add(8))
            == Some(final_rows),
        "The resumed match and no-fit need did not add eight expected attestation rows",
    )?;
    println!("ASSERT resumption environments (match + no-fit) OK");

    seller.post("/v1/offers", json!({"offer_id":"crystal-decanter-10","tenant":"elena-atelier","title":"Crystal decanter",
        "category":"housewares","region":"region-a","price_cents":8500,"deliver_by_days":7,"auto_close":true})).await?;
    poll(Duration::from_secs(30), Duration::from_secs(2), |_| async {
        require(
            seller.get("/v1/orders").await?["count"] == 3,
            "The decanter order is missing",
        )
    })
    .await
    .map_err(|_| {
        Failure::new(
            9,
            "offer-published event did not produce the decanter match",
        )
    })?;
    println!("ASSERT offer-published event path OK");

    let history = json_reply(
        &buyer(&coordinator, &identity, &["consents"]).await?,
        "consent history",
    )?;
    let uses = check_history(&history)?;
    println!("ASSERT consent history grant-revoke-regrant OK");
    println!("ASSERT {uses} match(es) recorded as consent uses, none while revoked OK");
    let consents = ledger.get("/v1/consents").await?;
    let use_count = entries(&consents)?
        .iter()
        .filter(|entry| entry["payload"]["action"] == "use")
        .count() as u64;
    let expected_rows = 6 + use_count;
    let proof = ledger.get("/v1/verify").await?;
    require(
        ["attestation_ok", "settlement_ok", "consent_ok"]
            .iter()
            .all(|chain| proof[*chain].as_bool() == Some(true))
            && proof["consent_len"].as_u64() == Some(expected_rows),
        "The consent or other ledger chains failed",
    )?;
    println!("ASSERT all three chains verify OK");
    let persisted = sql("SELECT count(*) FROM ledger.consent_ledger").await?;
    if persisted.parse::<u64>().ok() != Some(expected_rows) {
        return Err(Failure::new(
            9,
            format!("consent chain not persisted (rows: {persisted})"),
        ));
    }
    println!("ASSERT PostgreSQL consent write-through OK");
    println!("s003.silence HAPPY PATH PASSED");
    Ok(())
}
