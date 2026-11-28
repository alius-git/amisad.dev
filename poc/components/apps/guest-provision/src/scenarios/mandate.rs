// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 4210b173-11ca-45a8-bd58-a44d89496548

use super::{
    buyer, buyer_call, id,
    mediation::{json_reply, sql},
    require, Endpoint,
};
use crate::Failure;
use serde_json::{json, Value};
use std::net::IpAddr;

const ATTESTATIONS: &str = "SELECT count(*) FROM ledger.attestation_ledger";

async fn seller_orders(seller: &Endpoint) -> Result<u64, Failure> {
    seller.get("/v1/orders").await?["count"]
        .as_u64()
        .ok_or_else(|| Failure::new(1, "The seller reply has no order count"))
}

fn pseudonymous(value: &Value) -> bool {
    let text = value.to_string().to_ascii_lowercase();
    !text.contains("pat") && !text.contains("maya")
}

pub(super) async fn refused(
    coordinator: &Endpoint,
    identity: &Endpoint,
    args: &[&str],
    reason: &str,
) -> Result<(), Failure> {
    let output = buyer_call(coordinator, identity, args).await?;
    let reports_reason = [&output.stdout, &output.stderr]
        .iter()
        .any(|stream| String::from_utf8_lossy(stream).contains(reason));
    if output.status.success() || !reports_reason {
        return Err(Failure::new(
            9,
            format!("The buyer request did not fail with {reason}"),
        ));
    }
    Ok(())
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
    macro_rules! reply {
        ($arguments:expr, $label:expr) => {
            json_reply(&buyer(&coordinator, &identity, $arguments).await?, $label)?
        };
    }

    println!("== register edge + seed Elena's household offers ==");
    resource
        .post(
            "/v1/edges",
            json!({"region":"region-a","endpoint":slice_endpoint}),
        )
        .await?;
    seller.post("/v1/offers", json!({"offer_id":"serving-set-01","tenant":"elena-atelier",
        "title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,
        "deliver_by_days":10,"auto_close":false})).await?;
    seller.post("/v1/offers", json!({"offer_id":"premium-vase-06","tenant":"elena-atelier",
        "title":"Premium crystal vase","category":"housewares","region":"region-a","price_cents":18000,
        "deliver_by_days":10,"auto_close":false,"attributes":["premium"]})).await?;

    let mandate = reply!(
        &["grant-mandate", "pat", "housewares", "14000"],
        "mandate grant"
    );
    require(
        mandate["per_item_cents"] == 14000
            && mandate["principal"].is_string()
            && mandate["delegate"].is_string()
            && mandate["principal"] != mandate["delegate"]
            && pseudonymous(&mandate),
        "The scoped mandate is missing distinct pseudonymous parties",
    )?;
    println!("ASSERT mandate recorded (pseudonymous) OK");
    let workspace = reply!(&["workspace", "pat"], "delegate workspace");
    require(
        workspace["principals"].as_array().is_some_and(|values| {
            matches!(values.as_slice(), [principal]
        if principal["category"] == "housewares" && principal["per_item_cents"] == 14000)
        }),
        "The delegate workspace has the wrong principal or mandate cap",
    )?;
    println!("ASSERT delegate workspace shows the principal OK");

    let under = reply!(
        &["delegate-need", "pat", "housewares", "12000"],
        "under-cap match"
    );
    require(
        under["status"] == "committed" && under["via"] == "delegate",
        "The under-cap match did not commit on its mandate",
    )?;
    println!("ASSERT in-scope under-cap closes on delegate authority OK");
    sql(ATTESTATIONS).await?;
    let under_orders = seller_orders(&seller).await?;

    let activity = reply!(&["activity"], "buyer activity");
    let trail = activity["activity"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "There is no buyer activity trail"))?;
    let mut matched = trail
        .iter()
        .filter(|entry| entry["kind"] == "delegated-match" && entry["via"] == "delegate");
    require(
        matched.next().is_some_and(|entry| {
            entry["mandate"].as_bool() == Some(true)
                && entry["actor"].is_string()
                && entry["principal"].is_string()
                && entry["actor"] != entry["principal"]
        }) && matched.next().is_none()
            && pseudonymous(&activity["activity"]),
        "The delegated match lacks distinct pseudonymous attribution",
    )?;
    println!("ASSERT dual attribution on the activity trail OK");

    let held = reply!(
        &["delegate-need", "pat", "housewares", "20000", "premium"],
        "held match"
    );
    require(
        held["status"] == "held-for-approval",
        "The over-cap match was not held for approval",
    )?;
    let handle = id(&held, "handle")?;
    println!("ASSERT over-cap held for approval OK");
    let before_approval = seller_orders(&seller).await?;
    if before_approval != under_orders {
        return Err(Failure::new(
            9,
            format!(
                "over-cap match committed before approval ({under_orders} -> {before_approval})"
            ),
        ));
    }
    println!("ASSERT no over-cap closing before approval OK");

    let approved = reply!(&["approve", handle], "approved match");
    require(
        approved["status"] == "committed" && approved["via"] == "approval",
        "The over-cap match did not commit by principal approval",
    )?;
    println!("ASSERT over-cap closes via principal approval OK");
    require(
        under_orders.checked_add(1) == Some(seller_orders(&seller).await?),
        "Approval did not add exactly one order",
    )?;
    println!("ASSERT approved closing added one order OK");

    let before_out_of_scope = sql(ATTESTATIONS).await?;
    refused(
        &coordinator,
        &identity,
        &["delegate-need", "pat", "dresses", "20000"],
        "out of mandate scope",
    )
    .await?;
    let after_out_of_scope = sql(ATTESTATIONS).await?;
    if before_out_of_scope != after_out_of_scope {
        return Err(Failure::new(9, format!("out-of-scope attempt created environments ({before_out_of_scope} -> {after_out_of_scope})")));
    }
    println!("ASSERT out-of-scope refused with zero environments OK");

    let revoked = reply!(&["revoke-mandate", "pat"], "mandate revocation");
    require(
        revoked["revoked"].as_bool() == Some(true),
        "Mandate revocation failed",
    )?;
    println!("ASSERT mandate revoked OK");
    let workspace = reply!(&["workspace", "pat"], "revoked workspace");
    require(
        workspace["principals"]
            .as_array()
            .is_some_and(Vec::is_empty),
        "The revoked mandate remains in the delegate workspace",
    )?;
    println!("ASSERT delegate workspace cleared on revoke OK");
    refused(
        &coordinator,
        &identity,
        &["delegate-need", "pat", "housewares", "12000"],
        "no valid mandate",
    )
    .await?;
    println!("ASSERT no delegated action after revocation OK");

    let records = sql("SELECT count(*) FROM ledger.consent_ledger WHERE grant_type='mandate' AND payload::jsonb->>'action' IN ('grant','revoke')").await?;
    if records != "2" {
        return Err(Failure::new(
            9,
            format!("expected 2 mandate consent rows (grant+revoke), got {records}"),
        ));
    }
    let uses = sql("SELECT payload::jsonb->>'via' FROM ledger.consent_ledger WHERE grant_type='mandate' AND payload::jsonb->>'action' = 'use' ORDER BY id").await?;
    if !uses.lines().eq(["delegate", "approval"]) {
        return Err(Failure::new(
            9,
            "The consent ledger does not show exactly one delegated and one approved use",
        ));
    }
    let proof = ledger.get("/v1/verify").await?;
    require(
        ["attestation_ok", "settlement_ok", "consent_ok"]
            .iter()
            .all(|chain| proof[*chain].as_bool() == Some(true)),
        "A ledger chain failed after mandate revocation",
    )?;
    println!("ASSERT all three chains verify OK");
    println!("s006.mandate HAPPY PATH PASSED");
    Ok(())
}
