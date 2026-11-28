// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42760176-b7c4-454c-abc4-b54095b33981

use super::{
    buyer, entries, id,
    mediation::{json_reply, support_request},
    require, Endpoint,
};
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
    let platform = Endpoint::node(ip, 30086);
    let audit = Endpoint::node(ip, 30089);
    let slice = Endpoint::parse(slice_endpoint)?;

    println!("== self-seed the evidence corpus ==");
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
        "matched order",
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

    slice
        .exchange("/v1/faults", Some(json!({"mode":"isolation","count":1})))
        .await?;
    buyer(&coordinator, &identity, &["submit"]).await?;
    for arguments in [
        &["resume"][..],
        &["pause"],
        &["grant-mandate", "pat", "housewares", "14000"],
    ] {
        buyer(&coordinator, &identity, arguments).await?;
    }

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
    let case = json_reply(
        &support_request(
            &platform,
            "/v1/support/cases",
            json!({"token":token,"match_id":match_id,"metadata":{"order_state":"settled"}}),
        )
        .await?,
        "support case",
    )?;
    let case_id = id(&case, "case_id")?;
    support_request(
        &platform,
        "/v1/support/cases/disclosure/request",
        json!({"token":token,"case_id":case_id}),
    )
    .await?;
    buyer(
        &coordinator,
        &identity,
        &["disclose", case_id, "delivery-photo-ref-77", "120"],
    )
    .await?;
    support_request(
        &platform,
        "/v1/support/cases/refund",
        json!({"token":token,"case_id":case_id}),
    )
    .await?;
    println!("corpus seeded");

    println!("== Ingrid runs the certification: all four dimensions, zero violations ==");
    let certificate = audit.post_json("/v1/certify", Value::Null).await?;
    for dimension in ["attestation", "residency", "consent", "settlement"] {
        require(
            certificate[dimension]["ok"].as_bool() == Some(true)
                && certificate[dimension]["violations"] == 0,
            &format!("Audit certification failed in {dimension}"),
        )?;
    }
    require(
        certificate["certified"].as_bool() == Some(true) && certificate["total_violations"] == 0,
        "The complete corpus was not certified with zero violations",
    )?;
    println!("ASSERT four-dimension certification clean OK");

    let consents = ledger.get("/v1/consents").await?;
    let uses = || {
        entries(&consents).map(|entries| {
            entries
                .iter()
                .map(|entry| &entry["payload"])
                .filter(|payload| payload["action"] == "use")
        })
    };
    require(
        uses()?
            .any(|entry| entry["grant_type"] == "participation" && entry["match_id"] == match_id)
            && uses()?
                .any(|entry| entry["grant_type"] == "disclosure" && entry["scope"] == case_id),
        "Audit certified a corpus missing participation or disclosure use",
    )?;
    println!("ASSERT every seeded match and the disclosure carry a consent use OK");

    // Mutate only the submitted fixture copy. Preserve the active source
    // ledger and avoid persisting the certification corpus in temporary files.
    const INDEX: usize = 5;
    let mut attestations = ledger.get("/v1/attestations").await?;
    let entries = attestations["entries"]
        .as_array_mut()
        .ok_or_else(|| Failure::new(1, "There is no attestation corpus to check"))?;
    let payload = entries
        .get_mut(INDEX)
        .and_then(|row| row["payload"].as_object_mut())
        .ok_or_else(|| Failure::new(1, "The attestation corpus lacks the expected record"))?;
    payload.insert("lifecycle".into(), "tampered-lifecycle".into());
    let altered = audit
        .post_json("/v1/certify/tamper", json!({"entries":entries}))
        .await?;
    require(
        altered["detected"].as_bool() == Some(true)
            && altered["tampered_index"].as_u64() == Some(INDEX as u64),
        "The auditor failed to localize the altered fixture record",
    )?;
    println!("ASSERT tamper detected and localized OK");

    let incident = platform
        .post_json(
            "/v1/incidents",
            json!({"summary":"certification findings: corpus certified, tamper detected",
        "from":"audit","environment_ids":[environment]}),
        )
        .await?;
    id(&incident, "case_id")?;
    println!("ASSERT findings delivered to the platform OK");

    let access = audit.get("/v1/access-log").await?;
    let requests = access["access"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "The auditor emitted no access log"))?;
    require(
        requests.len() >= 3 && requests.iter().all(|entry| entry["method"] == "GET"),
        "The auditor lacks sufficient read-only evidence",
    )?;
    let public = access["access"].to_string().to_ascii_lowercase();
    for marker in ["maya", "subject", "need_context", "envelope", "password"] {
        require(
            !public.contains(marker),
            &format!("audit access log leaked: {marker}"),
        )?;
    }
    println!("ASSERT audit access is read-only, no personal data OK");
    println!("s010.certification HAPPY PATH PASSED");
    Ok(())
}
