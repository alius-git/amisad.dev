// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 420d2c58-e68a-4b98-b231-57ede811cc33

use super::{buyer, entries, id, require, Endpoint};
use crate::Failure;
use serde_json::{json, Value};
use std::net::IpAddr;

pub(crate) async fn run(node: &str, slice_endpoint: &str) -> Result<(), Failure> {
    let ip: IpAddr = node
        .parse()
        .map_err(|_| Failure::new(1, "The core node has no usable IP address"))?;
    let coordinator = Endpoint::node(ip, 30080);
    let ledger = Endpoint::node(ip, 30081);
    let resource = Endpoint::node(ip, 30082);
    let seller = Endpoint::node(ip, 30083);
    let identity = Endpoint::node(ip, 30084);
    let ads = Endpoint::node(ip, 30087);
    let slice = Endpoint::parse(slice_endpoint)?;

    println!("== register edge + seed Elena's summer offer ==");
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

    println!("== Marcel: campaign + brief; Kai: asset; Marcel: activate ==");
    let campaign = ads
        .post_json(
            "/v1/campaigns",
            json!({"tenant":"elena-atelier","region":"region-a","category":"housewares",
            "ad_cents_per_match":2000,"budget_cents":10000}),
        )
        .await?;
    let campaign_id = id(&campaign, "campaign_id")?;
    ads.post("/v1/briefs", json!({"campaign_id":campaign_id}))
        .await?;
    let briefs = ads.get("/v1/briefs").await?;
    require(
        briefs["briefs"]
            .as_array()
            .is_some_and(|rows| rows.iter().any(|row| row["campaign_id"] == campaign_id)),
        "The campaign brief is missing from the creative queue",
    )?;
    println!("ASSERT brief in creative queue OK");

    let asset = ads
        .post_json(
            "/v1/assets",
            json!({"campaign_id":campaign_id,"creator":"kai","creative":"summer-hero-01"}),
        )
        .await?;
    let asset_id = id(&asset, "asset_id")?;
    let active = ads
        .post_json(
            "/v1/campaigns/activate",
            json!({"campaign_id":campaign_id,"asset_id":asset_id}),
        )
        .await?;
    require(
        active["state"] == "active",
        "The campaign did not become active",
    )?;
    println!("ASSERT campaign active OK");

    println!("== Maya's need -> shortlist carries Elena's offer boosted with Kai's creative ==");
    let shortlist: Value =
        serde_json::from_slice(&buyer(&coordinator, &identity, &["campaign"]).await?)
            .map_err(|error| Failure::new(1, format!("Invalid campaign shortlist: {error}")))?;
    let handle = id(&shortlist, "handle")?;
    let offers = shortlist["shortlist"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "The buyer reply has no campaign shortlist"))?;
    let mut boosted = offers
        .iter()
        .filter(|offer| offer["offer_id"] == "serving-set-01");
    let entry = boosted
        .next()
        .ok_or_else(|| Failure::new(1, "The boosted offer is missing"))?;
    let boost = &entry["campaign"];
    require(
        boosted.next().is_none()
            && boost["campaign_id"] == campaign_id
            && boost["asset_id"] == asset_id
            && boost["creator"] == "kai"
            && boost["creative"] == "summer-hero-01",
        "The offer was duplicated or boosted with a different asset",
    )?;
    println!("ASSERT offer boosted with the creative OK");

    let ingress = slice.get("/v1/ingress").await?;
    require(
        entries(&ingress)?.iter().any(|entry| {
            entry
                .as_str()
                .is_some_and(|line| line.contains("summer-hero-01"))
        }),
        "The creative is missing from the ingress log",
    )?;
    println!("ASSERT creative in ingress log OK");

    println!("== Maya accepts -> the boosted match closes ==");
    let booking: Value = serde_json::from_slice(
        &buyer(&coordinator, &identity, &["book", handle, "serving-set-01"]).await?,
    )
    .map_err(|error| Failure::new(1, format!("Invalid campaign booking: {error}")))?;
    let match_id = id(&booking, "match_id")?;
    require(
        booking["boosted"].as_bool() == Some(true),
        "The booking lost its campaign boost",
    )?;
    println!("ASSERT booking is boosted OK");
    for state in ["provisioning", "fulfilled"] {
        seller
            .post(
                "/v1/orders/advance",
                json!({"match_id":match_id,"state":state}),
            )
            .await?;
    }
    let settlement = ledger
        .get(&format!("/v1/settlements/match/{match_id}"))
        .await?;
    require(
        settlement["confirmed"].as_bool() == Some(true)
            && settlement["total_cents"] == 13000
            && settlement["value_cents"] == 13000,
        "The campaign settlement differs from the confirmed match and ad value",
    )?;
    let parties = entries(&settlement)?;
    for (party, amount) in [("agency", 1200), ("creator", 800), ("seller", 9900)] {
        require(
            parties
                .iter()
                .rev()
                .find(|entry| entry["party"] == party)
                .is_some_and(|entry| entry["amount_cents"] == amount),
            &format!("The settlement has unexpected {party} credit"),
        )?;
    }
    println!("ASSERT agency + creator credit in settlement OK");

    let report = ads.get("/v1/attributions").await?;
    let attribution = &report["attributions"][0];
    require(
        report["closed_matches"] == 1
            && report["agency_cents_total"] == 1200
            && report["creator_cents_total"] == 800
            && attribution["campaign_id"] == campaign_id
            && attribution["asset_id"] == asset_id,
        "Campaign attribution disagrees with the ledger",
    )?;
    println!("ASSERT aggregate attribution consistent with ledger OK");
    let campaign = ads.get(&format!("/v1/campaigns/{campaign_id}")).await?;
    require(
        campaign["spent_cents"] == 2000,
        "Campaign spend differs from the per-match commitment",
    )?;
    println!("ASSERT campaign budget decrement OK");

    let public = ads
        .get("/v1/attributions")
        .await?
        .to_string()
        .to_ascii_lowercase();
    for marker in [
        "maya",
        "budget_cents",
        "deadline_days",
        "summer entertaining",
        "envelope",
    ] {
        require(
            !public.contains(marker),
            &format!("campaign side leaked: {marker}"),
        )?;
    }
    println!("ASSERT zero buyer signal on the campaign side OK");
    println!("s005.attribution HAPPY PATH PASSED");
    Ok(())
}
