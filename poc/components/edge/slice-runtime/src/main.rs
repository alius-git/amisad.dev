// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC slice-runtime: the sealed match environment on the edge VM. Each
// POST /v1/environments runs one lifecycle (created -> attested -> executed
// -> destroyed) written to the attestation ledger and mirrored to resource
// telemetry; the envelope is opened ONLY here, and everything that leaves is
// in the egress log, so zero-leak is checkable. Deviations: poc/README.md.

use amisad_common::{json, request, serve_app, sha256, Request, Response, ServiceInfo};
use std::time::{SystemTime, UNIX_EPOCH};

struct State {
    egress: Vec<String>,
}

fn ledger_url() -> String {
    std::env::var("LEDGER_URL").unwrap_or_else(|_| String::from("http://ledger-svc:8080"))
}
fn resource_url() -> String {
    std::env::var("RESOURCE_URL").unwrap_or_else(|_| String::from("http://resource-svc:8080"))
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

/// An offer fits when every stated constraint holds. Missing fields fail
/// closed: an offer that cannot prove it fits does not fit.
fn qualifies(need: &json::Json, offer: &json::Json) -> bool {
    let category_ok = match (need.str_of("category"), offer.str_of("category")) {
        (Some(n), Some(o)) => n == o,
        _ => false,
    };
    let price_ok = match (need.i64_of("budget_cents"), offer.i64_of("price_cents")) {
        (Some(budget), Some(price)) => price <= budget,
        _ => false,
    };
    let region_ok = match (need.str_of("region"), offer.str_of("region")) {
        (Some(n), Some(o)) => n == o,
        _ => false,
    };
    let deadline_ok = match (need.i64_of("deadline_days"), offer.i64_of("deliver_by_days")) {
        (Some(deadline), Some(days)) => days <= deadline,
        _ => false,
    };
    category_ok && price_ok && region_ok && deadline_ok
}

fn auto_closable(need: &json::Json, offer: &json::Json) -> bool {
    need.bool_of("auto_close") == Some(true) && offer.bool_of("auto_close") == Some(true)
}

/// Four-way split: network 5%, platform 5%, ads 0 (no campaign in this
/// scenario), seller the remainder - sums exactly by construction.
fn splits_for(value_cents: i64) -> (i64, i64, i64, i64) {
    let network = value_cents * 5 / 100;
    let platform = value_cents * 5 / 100;
    let ads = 0;
    let seller = value_cents - network - platform - ads;
    (seller, network, platform, ads)
}

/// Every outbound payload goes through here so the egress log is complete.
fn post_out(state: &mut State, kind: &str, url: &str, body: &json::Json) {
    let text = body.dump();
    state.egress.push(format!("{kind}:{text}"));
    if let Err(e) = request("POST", url, Some(&text)) {
        eprintln!("egress {kind} to {url} failed: {e}");
    }
}

fn attest(state: &mut State, environment_id: &str, jurisdiction: &str, lifecycle: &str) {
    let payload = json::obj(vec![
        ("environment_id", json::s(environment_id)),
        ("lifecycle", json::s(lifecycle)),
        ("jurisdiction", json::s(jurisdiction)),
    ]);
    post_out(
        state,
        "attestation",
        &format!("{}/v1/attestations", ledger_url()),
        &payload,
    );
    let telemetry = json::obj(vec![
        ("environment_id", json::s(environment_id)),
        ("event", json::s(lifecycle)),
    ]);
    post_out(
        state,
        "telemetry",
        &format!("{}/v1/telemetry", resource_url()),
        &telemetry,
    );
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/environments") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let jurisdiction = body.str_of("jurisdiction").unwrap_or("").to_string();
            let envelope = match body.str_of("envelope") {
                Some(e) => e.to_string(),
                None => return Response::error(400, "envelope required"),
            };
            let empty = Vec::new();
            let offers = body.get("offers").and_then(|o| o.as_arr()).unwrap_or(&empty).clone();

            let environment_id =
                sha256::hex_digest(format!("{envelope}|{}", now_nanos()).as_bytes());
            attest(state, &environment_id, &jurisdiction, "created");
            attest(state, &environment_id, &jurisdiction, "attested");

            // The envelope is opened only inside this environment.
            let need = match json::parse(&envelope) {
                Ok(n) => n,
                Err(e) => {
                    attest(state, &environment_id, &jurisdiction, "aborted");
                    attest(state, &environment_id, &jurisdiction, "destroyed");
                    return Response::error(400, &format!("bad envelope: {e}"));
                }
            };

            let best = offers
                .iter()
                .filter(|offer| qualifies(&need, offer) && auto_closable(&need, offer))
                .min_by_key(|offer| offer.i64_of("price_cents").unwrap_or(i64::MAX));

            let offer = match best {
                Some(o) => o.clone(),
                None => {
                    attest(state, &environment_id, &jurisdiction, "executed");
                    attest(state, &environment_id, &jurisdiction, "destroyed");
                    return Response::error(404, "no fitting offer");
                }
            };

            let offer_id = offer.str_of("offer_id").unwrap_or("").to_string();
            let value_cents = offer.i64_of("price_cents").unwrap_or(0);
            let match_id =
                sha256::hex_digest(format!("{environment_id}|{offer_id}").as_bytes());
            let (seller, network, platform, ads) = splits_for(value_cents);
            let instruction = json::obj(vec![
                ("match_id", json::s(&match_id)),
                ("value_cents", json::n(value_cents)),
                (
                    "splits",
                    json::obj(vec![
                        ("seller_cents", json::n(seller)),
                        ("network_cents", json::n(network)),
                        ("platform_cents", json::n(platform)),
                        ("ads_cents", json::n(ads)),
                    ]),
                ),
            ]);
            post_out(
                state,
                "settlement-instruction",
                &format!("{}/v1/settlements/instructions", ledger_url()),
                &instruction,
            );
            attest(state, &environment_id, &jurisdiction, "executed");

            // The match record: need_context is the shareable summary the
            // buyer chose to include; nothing else from the need leaves.
            let match_record = json::obj(vec![
                ("match_id", json::s(&match_id)),
                ("environment_id", json::s(&environment_id)),
                (
                    "offer",
                    json::obj(vec![
                        ("offer_id", json::s(&offer_id)),
                        ("tenant", json::s(offer.str_of("tenant").unwrap_or(""))),
                        ("title", json::s(offer.str_of("title").unwrap_or(""))),
                        ("price_cents", json::n(value_cents)),
                    ]),
                ),
                (
                    "need_context",
                    json::s(need.str_of("context").unwrap_or("")),
                ),
            ]);
            state.egress.push(format!("match-record:{}", match_record.dump()));
            attest(state, &environment_id, &jurisdiction, "destroyed");
            // Environment state (need, offers) drops here with the locals.
            Response::json(201, &match_record)
        }
        ("GET", "/v1/egress") => {
            let entries: Vec<json::Json> =
                state.egress.iter().map(|e| json::s(e)).collect();
            Response::json(200, &json::obj(vec![("entries", json::arr(entries))]))
        }
        _ => Response::error(404, "not found"),
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "slice-runtime",
            version: env!("CARGO_PKG_VERSION"),
        },
        State { egress: Vec::new() },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn need() -> json::Json {
        json::parse(
            "{\"category\":\"housewares\",\"budget_cents\":12000,\"region\":\"region-a\",\"deadline_days\":14,\"auto_close\":true,\"context\":\"wedding gift\"}",
        )
        .unwrap()
    }

    fn offer(price: i64, category: &str, region: &str, days: i64, auto: bool) -> json::Json {
        json::obj(vec![
            ("offer_id", json::s("o1")),
            ("tenant", json::s("elena-atelier")),
            ("title", json::s("serving set")),
            ("category", json::s(category)),
            ("region", json::s(region)),
            ("price_cents", json::n(price)),
            ("deliver_by_days", json::n(days)),
            ("auto_close", json::b(auto)),
        ])
    }

    #[test]
    fn qualification_checks_every_constraint() {
        let n = need();
        assert!(qualifies(&n, &offer(11000, "housewares", "region-a", 10, true)));
        assert!(!qualifies(&n, &offer(13000, "housewares", "region-a", 10, true))); // over budget
        assert!(!qualifies(&n, &offer(11000, "dresses", "region-a", 10, true))); // wrong category
        assert!(!qualifies(&n, &offer(11000, "housewares", "region-b", 10, true))); // wrong region
        assert!(!qualifies(&n, &offer(11000, "housewares", "region-a", 20, true))); // too slow
    }

    #[test]
    fn auto_close_requires_both_sides() {
        let n = need();
        assert!(auto_closable(&n, &offer(11000, "housewares", "region-a", 10, true)));
        assert!(!auto_closable(&n, &offer(11000, "housewares", "region-a", 10, false)));
    }

    #[test]
    fn splits_sum_exactly() {
        for value in [1i64, 99, 100, 101, 11999, 12000] {
            let (seller, network, platform, ads) = splits_for(value);
            assert_eq!(seller + network + platform + ads, value);
            assert!(seller >= 0 && network >= 0 && platform >= 0 && ads >= 0);
        }
    }
}
