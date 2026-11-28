// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42986e3b-975a-4a64-a810-797c89fba8dd

pub(crate) mod attribution;
pub(crate) mod certification;
pub(crate) mod failover;
pub(crate) mod inventory;
pub(crate) mod mandate;
pub(crate) mod mediation;
pub(crate) mod silence;

use crate::{child, poll, Failure};
use bytes::Bytes;
use http_body_util::{BodyExt, Full, Limited};
use hyper::{header, Method, Request, StatusCode, Uri};
use hyper_util::rt::TokioIo;
use serde_json::{json, Value};
use std::{
    net::{IpAddr, SocketAddr},
    process::{Output, Stdio},
    time::Duration,
};
use tokio::{net::TcpStream, process::Command, task::JoinSet, time::timeout};

const REQUEST_BUDGET: Duration = Duration::from_secs(30);
const RESPONSE_LIMIT: usize = 1024 * 1024;

pub(super) struct Endpoint {
    authority: String,
    connect: String,
}

impl Endpoint {
    fn node(ip: IpAddr, port: u16) -> Self {
        let authority = SocketAddr::new(ip, port).to_string();
        Self {
            connect: authority.clone(),
            authority,
        }
    }

    pub(super) fn parse(origin: &str) -> Result<Self, Failure> {
        let invalid = || Failure::new(1, "The slice-runtime endpoint is invalid");
        let uri: Uri = origin.parse().map_err(|_| invalid())?;
        let authority = uri.authority().ok_or_else(invalid)?;
        if uri.scheme_str() != Some("http")
            || uri.path() != "/"
            || uri.query().is_some()
            || authority.as_str().contains('@')
        {
            return Err(invalid());
        }
        let connect = match authority.port() {
            Some(_) => authority.to_string(),
            None => format!("{}:80", authority.host()),
        };
        Ok(Self {
            authority: authority.to_string(),
            connect,
        })
    }

    pub(super) fn url(&self) -> String {
        format!("http://{}", self.authority)
    }

    async fn request(
        &self,
        route: &str,
        data: Option<Value>,
    ) -> Result<(StatusCode, Bytes), Failure> {
        let method = if data.is_some() {
            Method::POST
        } else {
            Method::GET
        };
        let label = format!("{method} {}{route}", self.url());
        let failure = |error: &dyn std::error::Error| Failure::new(1, format!("{label}: {error}"));
        let transaction = async {
            let stream = TcpStream::connect(&self.connect)
                .await
                .map_err(|error| failure(&error))?;
            let (mut sender, connection) =
                hyper::client::conn::http1::handshake(TokioIo::new(stream))
                    .await
                    .map_err(|error| failure(&error))?;
            let mut network = JoinSet::new();
            network.spawn(connection);
            let mut request = Request::builder()
                .method(method)
                .uri(route)
                .header(header::HOST, &self.authority)
                .header(header::CONNECTION, "close");
            let body = match data {
                Some(value) => {
                    request = request.header(header::CONTENT_TYPE, "application/json");
                    Bytes::from(value.to_string())
                }
                None => Bytes::new(),
            };
            let response = sender
                .send_request(
                    request
                        .body(Full::new(body))
                        .map_err(|error| failure(&error))?,
                )
                .await
                .map_err(|error| failure(&error))?;
            let status = response.status();
            let body = Limited::new(response.into_body(), RESPONSE_LIMIT)
                .collect()
                .await
                .map_err(|error| failure(error.as_ref()))?
                .to_bytes();
            Ok((status, body))
        };
        timeout(REQUEST_BUDGET, transaction)
            .await
            .map_err(|_| Failure::new(124, format!("{label}: request timed out")))?
    }

    pub(super) async fn exchange(
        &self,
        route: &str,
        data: Option<Value>,
    ) -> Result<Bytes, Failure> {
        let method = if data.is_some() { "POST" } else { "GET" };
        let (status, body) = self.request(route, data).await?;
        if !status.is_success() {
            let detail = String::from_utf8_lossy(&body)
                .chars()
                .take(400)
                .collect::<String>();
            return Err(Failure::new(
                1,
                format!("{method} {}{route}: HTTP {status}: {detail}", self.url()),
            ));
        }
        Ok(body)
    }

    pub(super) async fn get(&self, route: &str) -> Result<Value, Failure> {
        serde_json::from_slice(&self.exchange(route, None).await?)
            .map_err(|error| Failure::new(1, format!("GET {}{route}: {error}", self.url())))
    }

    async fn post(&self, route: &str, body: Value) -> Result<(), Failure> {
        let bytes = self.exchange(route, Some(body)).await?;
        if !bytes.is_empty() {
            println!("{}", String::from_utf8_lossy(&bytes));
        }
        Ok(())
    }

    async fn post_json(&self, route: &str, body: Value) -> Result<Value, Failure> {
        serde_json::from_slice(&self.exchange(route, Some(body)).await?)
            .map_err(|error| Failure::new(1, format!("POST {}{route}: {error}", self.url())))
    }
}

fn require(passed: bool, diagnostic: &str) -> Result<(), Failure> {
    if passed {
        Ok(())
    } else {
        Err(Failure::new(1, diagnostic))
    }
}

fn id<'a>(payload: &'a Value, key: &str) -> Result<&'a str, Failure> {
    payload[key]
        .as_str()
        .filter(|value| {
            !value.is_empty()
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
        })
        .ok_or_else(|| Failure::new(1, format!("The buyer reply has an invalid {key}")))
}

async fn buyer(
    coordinator: &Endpoint,
    identity: &Endpoint,
    args: &[&str],
) -> Result<Vec<u8>, Failure> {
    let output = buyer_call(coordinator, identity, args).await?;
    if !output.status.success() {
        let exit = output
            .status
            .code()
            .and_then(|code| u8::try_from(code).ok())
            .unwrap_or(1);
        let detail = String::from_utf8_lossy(&output.stderr);
        let detail = detail.trim().chars().take(400).collect::<String>();
        return Err(Failure::new(
            exit,
            format!("buyer-client exited {exit}: {detail}"),
        ));
    }
    Ok(output.stdout)
}

async fn buyer_call(
    coordinator: &Endpoint,
    identity: &Endpoint,
    args: &[&str],
) -> Result<Output, Failure> {
    let mut command = Command::new("target/release/buyer-client");
    command
        .args(args)
        .env("COORDINATOR_URL", coordinator.url())
        .env("IDENTITY_URL", identity.url())
        .stdin(Stdio::null())
        .kill_on_drop(true);
    timeout(Duration::from_secs(300), command.output())
        .await
        .map_err(|_| Failure::new(124, "buyer-client exceeded its deadline"))?
        .map_err(|error| Failure::new(1, format!("buyer-client: {error}")))
}

async fn wait_after_restart(ledger: &Endpoint, seller: &Endpoint) -> Result<(), Failure> {
    poll(
        Duration::from_secs(120),
        Duration::from_secs(2),
        |_| async {
            for (endpoint, service) in [(ledger, "ledger-svc"), (seller, "seller-svc")] {
                endpoint.exchange("/health", None).await.map_err(|error| {
                    Failure::new(
                        8,
                        format!("{service} never came back after restart: {}", error.detail),
                    )
                })?;
            }
            Ok(())
        },
    )
    .await
    .map_err(|error| Failure::new(8, error.detail))
}

const ROW_COUNTS: &str = "SELECT (SELECT count(*) FROM ledger.settlement_ledger), (SELECT count(*) FROM ledger.attestation_ledger), (SELECT count(*) FROM seller.orders)";

fn verify_ledger(proof: &Value, reload: bool) -> Result<(), Failure> {
    require(
        proof["attestation_ok"].as_bool() == Some(true)
            && proof["settlement_ok"].as_bool() == Some(true),
        "The ledger failed hash-chain verification",
    )?;
    if reload {
        require(
            proof["settlement_len"]
                .as_u64()
                .is_some_and(|count| count >= 4)
                && proof["attestation_len"]
                    .as_u64()
                    .is_some_and(|count| count >= 4),
            "The ledgers lost entries after restart",
        )?;
    }
    Ok(())
}

pub(super) async fn fulfillment(node: &str, slice_endpoint: &str) -> Result<(), Failure> {
    let ip: IpAddr = node
        .parse()
        .map_err(|_| Failure::new(1, "The core node has no usable IP address"))?;
    let coordinator = Endpoint::node(ip, 30080);
    let ledger = Endpoint::node(ip, 30081);
    let resource = Endpoint::node(ip, 30082);
    let seller = Endpoint::node(ip, 30083);
    let identity = Endpoint::node(ip, 30084);
    let slice = Endpoint::parse(slice_endpoint)?;

    println!("== register edge + seed Elena's offers ==");
    resource
        .post(
            "/v1/edges",
            json!({"region": "region-a", "endpoint": slice_endpoint}),
        )
        .await?;
    for (offer, title, price, days) in [
        ("serving-set-01", "Ceramic serving set", 11000, 10),
        ("crystal-vase-02", "Crystal vase", 15000, 5),
    ] {
        seller
            .post(
                "/v1/offers",
                json!({"offer_id": offer, "tenant": "elena-atelier", "title": title,
                       "category": "housewares", "region": "region-a", "price_cents": price,
                       "deliver_by_days": days, "auto_close": true}),
            )
            .await?;
    }

    println!("== happy path: Maya's gift auto-closes ==");
    let result = buyer(&coordinator, &identity, &["submit"]).await?;
    let matched: Value = serde_json::from_slice(&result)
        .map_err(|error| Failure::new(1, format!("Invalid match reply: {error}")))?;
    println!("match: {}", String::from_utf8_lossy(&result).trim_end());
    let handle = id(&matched, "handle")?;
    let match_id = id(&matched, "match_id")?;
    let environment = id(&matched, "environment_id")?;
    let price = matched["offer"]["price_cents"]
        .as_u64()
        .ok_or_else(|| Failure::new(1, "The match has no price"))?;

    println!("== Elena ships ==");
    for state in ["provisioning", "fulfilled"] {
        seller
            .post(
                "/v1/orders/advance",
                json!({"match_id": match_id, "state": state}),
            )
            .await?;
    }
    let delivery = buyer(&coordinator, &identity, &["wait", handle]).await?;
    print!("{}", String::from_utf8_lossy(&delivery));

    let settlement = ledger
        .get(&format!("/v1/settlements/match/{match_id}"))
        .await?;
    require(
        settlement["confirmed"].as_bool() == Some(true),
        "settlement not confirmed",
    )?;
    require(
        settlement["total_cents"].as_u64() == Some(price)
            && settlement["value_cents"].as_u64() == Some(price),
        "Settlement splits do not sum to the match value",
    )?;
    let mut parties = entries(&settlement)?
        .iter()
        .map(|entry| entry["party"].as_str().unwrap_or(""))
        .collect::<Vec<_>>();
    parties.sort_unstable();
    require(
        parties == ["ads", "network", "platform", "seller"],
        "Unexpected settlement parties",
    )?;
    println!("ASSERT settlement OK");

    let seller_order = format!("/v1/orders/match/{match_id}");
    let order = seller.get(&seller_order).await?;
    require(
        order["state"] == "settled" && order["match_id"] == match_id,
        "The seller order is not settled for the expected match",
    )?;
    require(
        !order.to_string().to_ascii_lowercase().contains("buyer"),
        "seller order leaked buyer field",
    )?;
    println!("ASSERT seller order OK");
    let delivered = coordinator.get(&format!("/v1/orders/{handle}")).await?;
    require(
        delivered["status"] == "delivered",
        "The buyer's order is not delivered",
    )?;
    println!("ASSERT buyer status OK");

    let attestation = ledger
        .get(&format!("/v1/attestations/env/{environment}"))
        .await?;
    let lifecycle = entries(&attestation)?;
    for want in ["created", "attested", "executed", "destroyed"] {
        require(
            lifecycle.iter().any(|entry| entry["lifecycle"] == want),
            &format!("Missing {want} from the attestation lifecycle"),
        )?;
    }
    println!("ASSERT attestation lifecycle OK");
    verify_ledger(&ledger.get("/v1/verify").await?, false)?;
    println!("ASSERT hash chains OK");

    let egress = slice
        .get("/v1/egress")
        .await?
        .to_string()
        .to_ascii_lowercase();
    for marker in [
        "maya",
        "token",
        "budget_cents",
        "deadline_days",
        "subscriber",
    ] {
        require(
            !egress.contains(marker),
            &format!("egress leaked: {marker}"),
        )?;
    }
    println!("ASSERT zero egress OK");

    println!("== durable store: rows in PostgreSQL, state survives a pod restart ==");
    let result = child(
        "sudo",
        &["-u", "postgres", "psql", "-d", "amisad", "-tAc", ROW_COUNTS],
        REQUEST_BUDGET,
    )
    .await?;
    let rows = String::from_utf8_lossy(&result.stdout);
    let counts = rows
        .trim()
        .split('|')
        .map(str::parse::<u64>)
        .collect::<Result<Vec<_>, _>>();
    let has_rows = matches!(counts.as_deref(), Ok([settlements, attestations, orders]) if *settlements >= 4 && *attestations >= 4 && *orders >= 1);
    println!("pg rows (settlement|attestation|orders): {}", rows.trim());
    require(has_rows, "PostgreSQL is missing expected durable rows")?;
    println!("ASSERT PostgreSQL write-through OK");
    child(
        "kubectl",
        &[
            "-n",
            "amisad",
            "rollout",
            "restart",
            "deployment/ledger-svc",
            "deployment/seller-svc",
        ],
        REQUEST_BUDGET,
    )
    .await?;
    for deployment in ["deployment/ledger-svc", "deployment/seller-svc"] {
        let result = child(
            "kubectl",
            &[
                "-n",
                "amisad",
                "rollout",
                "status",
                deployment,
                "--timeout=180s",
            ],
            Duration::from_secs(185),
        )
        .await?;
        print!("{}", String::from_utf8_lossy(&result.stdout));
    }
    wait_after_restart(&ledger, &seller).await?;
    verify_ledger(&ledger.get("/v1/verify").await?, true)?;
    println!("ASSERT ledgers reloaded after restart OK");
    require(
        seller.get(&seller_order).await?["state"] == "settled",
        "The settled order was lost after restart",
    )?;
    println!("ASSERT order survived restart OK");
    println!("s001.fulfillment HAPPY PATH PASSED");
    Ok(())
}

fn entries(payload: &Value) -> Result<&[Value], Failure> {
    payload["entries"]
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| Failure::new(1, "The ledger reply has no entries"))
}

pub(super) async fn suppression(node: &str) -> Result<(), Failure> {
    let ip: IpAddr = node
        .parse()
        .map_err(|_| Failure::new(1, "The core node has no usable IP address"))?;
    let insights = Endpoint::node(ip, 30085);
    let seller = Endpoint::node(ip, 30083);
    let ads = Endpoint::node(ip, 30087);

    println!("== seed demand: region-a housewares ABOVE threshold, region-b BELOW ==");
    let record = |kind: &str, region: &str| {
        insights.exchange(
            "/v1/insights/record",
            Some(json!({"category": "housewares", "region": region, "kind": kind})),
        )
    };
    for _ in 0..6 {
        record("need", "region-a").await?;
    }
    for _ in 0..2 {
        record("offer", "region-a").await?;
        record("need", "region-b").await?;
    }
    let workbench = insights.get("/v1/workbench").await?;
    let aggregates = workbench["aggregates"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "The workbench has no aggregates"))?;
    let demand = |region: &str| {
        aggregates
            .iter()
            .rev()
            .find(|cell| cell["category"] == "housewares" && cell["region"] == region)
    };
    require(
        workbench["threshold"] == 5
            && demand("region-a").is_some_and(|cell| cell["demand"] == 6)
            && demand("region-b").is_none(),
        "The workbench did not suppress below-threshold demand",
    )?;
    println!("ASSERT below-threshold region suppressed from the workbench OK");

    println!("== Dana publishes a versioned outlook ==");
    let outlook = insights
        .post_json("/v1/outlooks", json!({"version": "2026-Q3"}))
        .await?;
    require(
        outlook["aggregates"].as_array().is_some_and(|rows| {
            !rows.is_empty() && rows.iter().all(|row| row["region"] == "region-a")
        }),
        "The published outlook carries unexpected regions",
    )?;
    println!("ASSERT published outlook carries only above-threshold figures OK");

    let seller_view = seller.get("/v1/demand-outlook/2026-Q3").await?;
    let ads_view = ads.get("/v1/demand-view/2026-Q3").await?;
    let published = insights.get("/v1/outlooks/2026-Q3").await?;
    require(
        seller_view == ads_view && ads_view == published && published["version"] == "2026-Q3",
        "Seller and ads demand views do not agree with the published outlook",
    )?;
    println!("ASSERT seller view == ads view == published outlook OK");

    let unmet = insights.get("/v1/unmet-demand").await?;
    let flags = unmet["unmet"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "The unmet-demand view has no flags"))?;
    let contains = |region: &str| {
        flags
            .iter()
            .any(|flag| flag["category"] == "housewares" && flag["region"] == region)
    };
    require(
        contains("region-a")
            && !contains("region-b")
            && flags.iter().all(|flag| {
                flag.as_object().is_some_and(|fields| {
                    fields.len() == 2
                        && fields.contains_key("category")
                        && fields.contains_key("region")
                })
            }),
        "Unexpected unmet-demand flags or fields",
    )?;
    println!("ASSERT unmet-demand flag (category+region only) OK");

    let workbench_readback = insights.get("/v1/workbench").await?;
    let unmet_readback = insights.get("/v1/unmet-demand").await?;
    for view in [
        &seller_view,
        &ads_view,
        &published,
        &workbench_readback,
        &unmet_readback,
    ] {
        require(
            !view.to_string().contains("region-b"),
            "below-threshold region leaked downstream",
        )?;
    }
    println!("ASSERT below-threshold region appears nowhere downstream OK");
    println!("s009.suppression HAPPY PATH PASSED");
    Ok(())
}

fn fitting_offer(
    identity: [&str; 3],
    terms: (&str, u64, u64),
    attributes: &[&str],
    slots: &[(&str, &str, u64)],
) -> Value {
    let [offer, tenant, title] = identity;
    let (region, price, days) = terms;
    let slots: Vec<_> = slots
        .iter()
        .map(|(id, day, ordinal)| json!({"slot_id": id, "day": day, "day_ordinal": ordinal}))
        .collect();
    json!({"offer_id": offer, "tenant": tenant, "title": title, "category": "dresses",
           "region": region, "price_cents": price, "deliver_by_days": days, "auto_close": false,
           "attributes": attributes, "fitting_slots": slots})
}

async fn verify_notifications(
    coordinator: &Endpoint,
    identity: &Endpoint,
    handle: &str,
    expected: &[&str],
) -> Result<(), Failure> {
    let bytes = buyer(coordinator, identity, &["notifications", handle]).await?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|error| Failure::new(1, format!("Invalid notification log: {error}")))?;
    require(
        value["notifications"]
            .as_array()
            .is_some_and(|notifications| {
                notifications
                    .iter()
                    .map(|entry| entry["kind"].as_str().unwrap_or(""))
                    .eq(expected.iter().copied())
            }),
        "Unexpected buyer notifications",
    )
}

pub(super) async fn fitting(node: &str, slice_endpoint: &str) -> Result<(), Failure> {
    let ip: IpAddr = node
        .parse()
        .map_err(|_| Failure::new(1, "The core node has no usable IP address"))?;
    Endpoint::parse(slice_endpoint)?;
    let coordinator = Endpoint::node(ip, 30080);
    let ledger = Endpoint::node(ip, 30081);
    let resource = Endpoint::node(ip, 30082);
    let seller = Endpoint::node(ip, 30083);
    let identity = Endpoint::node(ip, 30084);
    resource
        .post(
            "/v1/edges",
            json!({"region": "region-a", "endpoint": slice_endpoint}),
        )
        .await?;
    println!("== seed: Elena's dresses (one dusty blue), a second seller's misfits, slots ==");
    let required = ["midi", "sleeves", "warm-fabric"];
    for offer in [
        fitting_offer(
            ["linen-midi-04", "elena-atelier", "Linen midi dress"],
            ("region-a", 18000, 3),
            &required,
            &[("thu-1", "thursday", 4), ("sat-1", "saturday", 6)],
        ),
        fitting_offer(
            ["dusty-blue-02", "elena-atelier", "Dusty blue midi dress"],
            ("region-a", 16000, 3),
            &["midi", "sleeves", "warm-fabric", "dusty-blue"],
            &[("thu-2", "thursday", 4)],
        ),
        fitting_offer(
            ["silk-slip-03", "elena-atelier", "Silk slip dress"],
            ("region-a", 15000, 3),
            &["midi", "sleeveless"],
            &[("thu-3", "thursday", 4)],
        ),
        fitting_offer(
            ["wool-midi-07", "brisa-outlet", "Wool midi dress"],
            ("region-a", 14000, 30),
            &required,
            &[("wed-7", "wednesday", 3)],
        ),
        fitting_offer(
            ["linen-wrap-08", "brisa-outlet", "Linen wrap dress"],
            ("region-b", 13000, 2),
            &required,
            &[("thu-8", "thursday", 4)],
        ),
    ] {
        seller.post("/v1/offers", offer).await?;
    }

    println!("== Maya's manual dress need -> shortlist (notification 1) ==");
    let source = buyer(&coordinator, &identity, &["shortlist"]).await?;
    let shortlist: Value = serde_json::from_slice(&source)
        .map_err(|error| Failure::new(1, format!("Invalid shortlist: {error}")))?;
    println!("shortlist: {}", String::from_utf8_lossy(&source).trim_end());
    let handle = id(&shortlist, "handle")?;
    let offers = shortlist["shortlist"]
        .as_array()
        .ok_or_else(|| Failure::new(1, "The buyer reply has no shortlist"))?;
    let contains = |name: &str| offers.iter().any(|offer| offer["offer_id"] == name);
    require(
        contains("linen-midi-04"),
        "The qualifying offer is missing from the shortlist",
    )?;
    for denied in [
        "dusty-blue-02",
        "silk-slip-03",
        "wool-midi-07",
        "linen-wrap-08",
    ] {
        require(
            !contains(denied),
            &format!("{denied} leaked onto the shortlist"),
        )?;
    }
    println!("ASSERT shortlist constraint fidelity OK");
    require(
        seller.get("/v1/orders").await?["count"] == 0,
        "A commitment exists before booking",
    )?;
    println!("ASSERT zero pre-booking commitments OK");
    verify_notifications(&coordinator, &identity, handle, &["shortlist"]).await?;
    println!("ASSERT single shortlist notification OK");

    println!("== Maya books the Thursday fitting (notification 2) ==");
    let source = buyer(
        &coordinator,
        &identity,
        &["book", handle, "linen-midi-04", "thu-1"],
    )
    .await?;
    let booking: Value = serde_json::from_slice(&source)
        .map_err(|error| Failure::new(1, format!("Invalid booking: {error}")))?;
    println!("booking: {}", String::from_utf8_lossy(&source).trim_end());
    let match_id = id(&booking, "match_id")?;
    let order = seller.get(&format!("/v1/orders/match/{match_id}")).await?;
    require(
        order["match_id"] == match_id
            && order["state"] == "committed"
            && order["appointment"]["slot_id"] == "thu-1"
            && booking["slot_id"] == "thu-1"
            && order["appointment"]["day"] == "thursday",
        "The seller appointment differs from the Thursday booking",
    )?;
    require(
        !order.to_string().to_ascii_lowercase().contains("buyer"),
        "seller appointment leaked buyer field",
    )?;
    println!("ASSERT appointment records OK");

    println!("== Elena: fitting fulfilled, sale closed -> settled with split ==");
    for state in ["provisioning", "fulfilled"] {
        seller
            .post(
                "/v1/orders/advance",
                json!({"match_id": match_id, "state": state}),
            )
            .await?;
    }
    let settlement = ledger
        .get(&format!("/v1/settlements/match/{match_id}"))
        .await?;
    require(
        settlement["confirmed"].as_bool() == Some(true)
            && settlement["total_cents"] == 18000
            && settlement["value_cents"] == 18000,
        "The confirmed settlement differs from the booked value",
    )?;
    println!("ASSERT settlement split OK");
    verify_notifications(
        &coordinator,
        &identity,
        handle,
        &["shortlist", "booking-confirmed"],
    )
    .await?;
    println!("ASSERT exactly two notifications OK");

    let result = child(
        "sudo",
        &[
            "-u",
            "postgres",
            "psql",
            "-d",
            "amisad",
            "-tAc",
            "SELECT count(*) FROM seller.orders WHERE slot_id = 'thu-1' AND state = 'settled'",
        ],
        REQUEST_BUDGET,
    )
    .await?;
    let rows = String::from_utf8_lossy(&result.stdout);
    if !rows.trim().parse::<u64>().is_ok_and(|count| count > 0) {
        return Err(Failure::new(
            9,
            format!("no settled thu-1 order in PostgreSQL (got {})", rows.trim()),
        ));
    }
    println!("ASSERT PostgreSQL appointment row OK");
    println!("s002.fitting HAPPY PATH PASSED");
    Ok(())
}
