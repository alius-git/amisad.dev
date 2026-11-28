// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42ca06df-3f76-4d2e-8f4a-1f70b3c82f1c

use super::{buyer, id, mediation::json_reply, require, Endpoint};
use crate::{poll, Failure};
use hyper::StatusCode;
use serde_json::{json, Value};
use std::{
    net::IpAddr,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

fn epoch_seconds() -> Result<u64, Failure> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .map_err(|_| Failure::new(1, "The system clock is earlier than the Unix epoch"))
}

async fn connector(endpoint: &Endpoint, route: &str, request: Value) -> Result<Value, Failure> {
    let (status, reply) = endpoint.request(route, Some(request)).await?;
    // A diagnostic from the connector can echo the scoped credential.
    // Preserve its HTTP status while keeping the reply inside this request.
    require(
        status.is_success(),
        &format!("POST {}{route}: HTTP {status}", endpoint.url()),
    )?;
    json_reply(&reply, "connector")
}

fn offer_available(response: &Value, offer: &str) -> Result<bool, Failure> {
    let offers = response["offers"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "The seller reply has no offers"))?;
    Ok(offers.iter().any(|row| row["offer_id"] == offer))
}

pub(crate) async fn run(node: &str, slice_endpoint: &str) -> Result<(), Failure> {
    let ip: IpAddr = node
        .parse()
        .map_err(|_| Failure::new(1, "The core node has no usable IP address"))?;
    Endpoint::parse(slice_endpoint)?;
    let coordinator = Endpoint::node(ip, 30080);
    let resource = Endpoint::node(ip, 30082);
    let seller = Endpoint::node(ip, 30083);
    let identity = Endpoint::node(ip, 30084);
    let connect = Endpoint::node(ip, 30088);
    resource
        .post(
            "/v1/edges",
            json!({"region":"region-a","endpoint":slice_endpoint}),
        )
        .await?;

    println!("== Alex registers + certifies a connector (sandbox only) ==");
    let partner = connect
        .post_json("/v1/partners", json!({"name":"alex-erp-connector"}))
        .await?;
    let partner_id = id(&partner, "partner_id")?;
    require(
        partner["access"] == "sandbox",
        "A new connector has access outside its sandbox",
    )?;
    println!("ASSERT sandbox access only OK");
    let certified = connect
        .post_json("/v1/partners/certify", json!({"partner_id":partner_id}))
        .await?;
    require(
        certified["certified"].as_bool() == Some(true),
        "The connector was not certified",
    )?;
    println!("ASSERT connector certified OK");

    println!("== Elena grants scoped access (catalog, inventory, orders) ==");
    let grant = connector(&connect, "/v1/grants",
        json!({"tenant":"elena-atelier","partner_id":partner_id,"scopes":["catalog","inventory","orders"]})).await?;
    let credential = grant["credential"]
        .as_str()
        .filter(|secret| !secret.is_empty())
        .ok_or_else(|| Failure::new(1, "The connector issued no scoped credential"))?;
    println!("ASSERT scoped credential issued OK");

    let offers = [("erp-lamp-01", "ERP table lamp", 8000), ("erp-clock-02", "ERP wall clock", 9000)]
        .map(|(id, title, price)| json!({"offer_id":id,"tenant":"elena-atelier","title":title,
            "category":"housewares","region":"region-a","price_cents":price,"deliver_by_days":5,"auto_close":true}));
    let synced = connector(
        &connect,
        "/v1/sync/catalog",
        json!({"credential":credential,"offers":offers}),
    )
    .await?;
    require(
        synced["synced"] == 2,
        "The connector did not sync both offers",
    )?;
    println!("ASSERT catalog synced OK");
    let catalog = "/v1/offers/region/region-a";
    let listed = seller.get(catalog).await?;
    require(
        offer_available(&listed, "erp-lamp-01")? && offer_available(&listed, "erp-clock-02")?,
        "The synced offers are missing from the seller catalog",
    )?;
    println!("ASSERT synced offers matchable OK");

    let delta_ts = epoch_seconds()?;
    let delta = connector(
        &connect,
        "/v1/sync/inventory",
        json!({"credential":credential,"offer_id":"erp-lamp-01","stock":0,"delta_ts":delta_ts}),
    )
    .await?;
    require(
        delta["stock"] == 0,
        "The connector did not apply zero stock",
    )?;
    println!("ASSERT inventory delta applied OK");
    let listed = seller.get(catalog).await?;
    require(
        !offer_available(&listed, "erp-lamp-01")? && offer_available(&listed, "erp-clock-02")?,
        "The zero-stock item remains matchable or the alternative is absent",
    )?;
    println!("ASSERT zeroed item left the catalog OK");
    let matched = json_reply(
        &buyer(&coordinator, &identity, &["submit"]).await?,
        "matched order",
    )?;
    let match_id = id(&matched, "match_id")?;
    require(
        matched["offer"]["offer_id"] == "erp-clock-02",
        "The buyer did not match the in-stock alternative",
    )?;
    println!("ASSERT match went to the in-stock alternative OK");
    let logged = connect.get("/v1/deltas").await?;
    let deltas = logged["deltas"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "The connector reply has no inventory deltas"))?;
    let mut zeroed = deltas
        .iter()
        .filter(|row| row["offer_id"] == "erp-lamp-01" && row["stock"] == 0);
    require(
        zeroed
            .next()
            .and_then(|row| row["delta_ts"].as_u64())
            .is_some_and(|seen| seen <= delta_ts.saturating_add(5))
            && zeroed.next().is_none(),
        "The logged inventory delta is duplicated or has the wrong timestamp",
    )?;
    println!("ASSERT inventory delta timestamped OK");

    for state in ["provisioning", "fulfilled"] {
        seller
            .post(
                "/v1/orders/advance",
                json!({"match_id":match_id,"state":state}),
            )
            .await?;
    }
    let erp_order = format!("/v1/erp/orders/{match_id}");
    poll(Duration::from_secs(30), Duration::from_secs(2), |_| async {
        require(
            connect.get(&erp_order).await?["state"] == "settled",
            "ERP mirror is not settled",
        )
    })
    .await
    .map_err(|_| Failure::new(9, "ERP mirror did not converge to settlement"))?;
    let seller_order = seller.get(&format!("/v1/orders/match/{match_id}")).await?;
    if seller_order["state"] != "settled" {
        return Err(Failure::new(9, "The seller order is not settled"));
    }
    println!("ASSERT ERP mirror equals seller state at settlement OK");

    let (status, body) = connect
        .request(
            "/v1/query",
            Some(json!({"credential":credential,"resource":"settlement"})),
        )
        .await?;
    if status != StatusCode::FORBIDDEN || String::from_utf8_lossy(&body).contains("\"ok\"") {
        return Err(Failure::new(
            9,
            format!("The out-of-scope request returned data or the wrong status ({status})"),
        ));
    }
    let audit = connect.get("/v1/audit").await?;
    require(
        audit["audit"].as_array().is_some_and(|rows| {
            rows.iter()
                .any(|row| row["scope"] == "settlement" && row["event"] == "out-of-scope")
        }),
        "The out-of-scope refusal was not audited",
    )?;
    println!("ASSERT out-of-scope refused and logged OK");

    let replay = connect
        .post_json(
            "/v1/webhooks/replay",
            json!({"match_id":match_id,"state":"settled"}),
        )
        .await?;
    require(
        replay["duplicate"].as_bool() == Some(true),
        "The webhook did not recognize the prior delivery",
    )?;
    println!("ASSERT replay is idempotent OK");
    let revoked = connector(
        &connect,
        "/v1/grants/revoke",
        json!({"credential":credential}),
    )
    .await?;
    require(
        revoked["revoked"].as_bool() == Some(true),
        "The integration grant was not revoked",
    )?;
    let (status, _) = connect.request("/v1/sync/inventory",
        Some(json!({"credential":credential,"offer_id":"erp-clock-02","stock":0,"delta_ts":epoch_seconds()?}))).await?;
    if status != StatusCode::UNAUTHORIZED {
        return Err(Failure::new(
            9,
            format!("Sync after revocation returned {status}"),
        ));
    }
    require(
        offer_available(&seller.get(catalog).await?, "erp-clock-02")?,
        "The revoked credential modified the catalog",
    )?;
    println!("ASSERT credentials die on revoke; catalog intact OK");

    for route in ["/v1/audit", "/v1/deltas"] {
        let report = connect.get(route).await?.to_string().to_ascii_lowercase();
        for marker in [
            "maya",
            "wedding gift",
            "budget_cents",
            "deadline_days",
            "envelope",
        ] {
            require(
                !report.contains(marker),
                &format!("integration surface leaked: {marker}"),
            )?;
        }
    }
    println!("ASSERT zero buyer signal on the integration surface OK");
    println!("s007.inventory HAPPY PATH PASSED");
    Ok(())
}
