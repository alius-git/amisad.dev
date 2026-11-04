// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 4211db43-989f-4894-8fb0-e7e120b5c2b5
// AmisAd POC slice-runtime: the sealed match environment on the edge VM. Each
// POST /v1/environments runs one lifecycle (created -> attested -> executed
// -> destroyed) written to the attestation ledger and mirrored to resource
// telemetry; the envelope is opened ONLY here, and everything that leaves is
// in the egress log, so zero-leak is checkable. s004.failover: the harness
// can arm isolation faults (POST /v1/faults) - an armed environment
// self-terminates right after attestation, BEFORE the envelope is opened
// (created -> attested -> aborted -> destroyed, fault reason attested, no
// match record, nothing need-derived leaves). Started with ADVERTISE_URL, the
// runtime registers itself with resource-svc under a lease it keeps renewing.
// Its ledger appends carry LEDGER_WRITE_TOKEN, which the scenario start hands
// over on standard input. Deviations: poc/README.md.

use amisad_common::{json, ledger_write_authorization, request, request_with_headers, serve_app, sha256, splits_for, Request, Response, ServiceInfo};
use std::io::Read;
use std::sync::OnceLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(test)]
type HttpSender = Box<dyn FnMut(&str, &str, Option<&str>, &[(&str, &str)]) -> Result<(u16, String), String> + Send>;

struct State {
    egress: Vec<String>,
    ingress: Vec<String>,
    armed_faults: i64,
    #[cfg(test)]
    http_sender: Option<HttpSender>,
}

fn ledger_url() -> String {
    std::env::var("LEDGER_URL").unwrap_or_else(|_| String::from("http://ledger-svc:8080"))
}
fn resource_url() -> String {
    std::env::var("RESOURCE_URL").unwrap_or_else(|_| String::from("http://resource-svc:8080"))
}
/// The slice's own region identity (set at process start by the operator that
/// placed it); rides in every attestation so out-of-region allocation is
/// assertable from the ledger alone.
fn region() -> String {
    std::env::var("REGION").unwrap_or_default()
}

/// The lease a self-registration asks for, and how often it is renewed: the
/// lease spans three renewals, so one lost POST keeps the edge placed.
const LEASE_SECS: i64 = 30;
const LEASE_RENEWAL: Duration = Duration::from_secs(10);

/// The edge's own registration when ADVERTISE_URL, REGION and RESOURCE_URL are
/// all set: the resource-svc URL and the POST /v1/edges body, with CAPACITY or
/// 1. Without them the runtime registers nothing and is registered from
/// outside, as the scenario scripts do.
fn advertisement() -> Option<(String, String)> {
    let setting = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
    let (endpoint, region, resource) = (setting("ADVERTISE_URL")?, setting("REGION")?, setting("RESOURCE_URL")?);
    let capacity = setting("CAPACITY").map_or(Ok(1), |text| text.parse::<i64>()).unwrap_or_else(|_| {
        eprintln!("CAPACITY is not an integer; registering capacity 1");
        1
    });
    let registration = json::obj(vec![
        ("region", json::s(&region)),
        ("endpoint", json::s(&endpoint)),
        ("capacity", json::n(capacity)),
        ("lease_secs", json::n(LEASE_SECS)),
    ]);
    Some((resource, registration.dump()))
}

/// Registers the edge and renews its lease for as long as the process runs.
/// A failure only goes to stderr: the registration is not environment egress.
fn renew_lease(resource: &str, registration: &str) {
    loop {
        match request("POST", &format!("{resource}/v1/edges"), Some(registration)) {
            Ok((201, _)) => {}
            Ok((status, body)) => eprintln!("lease renewal to {resource} returned {status}: {body}"),
            Err(e) => eprintln!("lease renewal to {resource} failed: {e}"),
        }
        std::thread::sleep(LEASE_RENEWAL);
    }
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

/// Process-local secret mixed into environment ids. Without it the id is a
/// weakly-salted commitment to the need plaintext: ids are published on
/// operator surfaces (incidents, cases, the attestation ledger), and a
/// guessed envelope plus a coarse timestamp could be brute-force-CONFIRMED
/// against sha256(envelope|nanos). The nonce never leaves the process.
fn process_nonce() -> &'static str {
    static NONCE: OnceLock<String> = OnceLock::new();
    NONCE.get_or_init(|| {
        let mut buf = [0u8; 32];
        match std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut buf)) {
            Ok(()) => sha256::hex_digest(&buf),
            // Non-Linux fallback (host-side tests): weaker, still per-process.
            Err(_) => sha256::hex_digest(
                format!("{}|{}", now_nanos(), std::process::id()).as_bytes(),
            ),
        }
    })
}

/// Attribute constraints (s002.fitting): every required attribute must be on
/// the offer, and no excluded attribute may be. A need that states nothing
/// requires nothing; an offer missing a required attribute fails closed.
fn attributes_ok(need: &json::Json, offer: &json::Json) -> bool {
    let empty = Vec::new();
    let offer_attrs: Vec<&str> = offer
        .get("attributes")
        .and_then(|a| a.as_arr())
        .unwrap_or(&empty)
        .iter()
        .filter_map(|a| a.as_str())
        .collect();
    if let Some(required) = need.get("attributes").and_then(|a| a.as_arr()) {
        for want in required {
            match want.as_str() {
                Some(w) if offer_attrs.contains(&w) => {}
                _ => return false,
            }
        }
    }
    if let Some(excluded) = need.get("exclusions").and_then(|a| a.as_arr()) {
        for banned in excluded {
            if let Some(b) = banned.as_str() {
                if offer_attrs.contains(&b) {
                    return false;
                }
            }
        }
    }
    true
}

/// A stated fitting requirement (day ordinal, Monday=1) needs at least one
/// bookable slot strictly earlier. No requirement stated = no check.
fn fitting_ok(need: &json::Json, offer: &json::Json) -> bool {
    let before = match need.i64_of("fitting_before_ordinal") {
        Some(d) => d,
        None => return true,
    };
    offer
        .get("fitting_slots")
        .and_then(|s| s.as_arr())
        .is_some_and(|slots| {
            slots
                .iter()
                .any(|slot| slot.i64_of("day_ordinal").is_some_and(|d| d < before))
        })
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
    category_ok
        && price_ok
        && region_ok
        && deadline_ok
        && attributes_ok(need, offer)
        && fitting_ok(need, offer)
}

fn auto_closable(need: &json::Json, offer: &json::Json) -> bool {
    need.bool_of("auto_close") == Some(true) && offer.bool_of("auto_close") == Some(true)
}

/// Every outbound payload goes through here so the egress log is complete.
/// `authorization` is the ledger write token's header value for a ledger
/// append, and None for any other peer.
fn post_out(state: &mut State, kind: &str, url: &str, body: &json::Json, authorization: Option<&str>) {
    let text = body.dump();
    state.egress.push(format!("{kind}:{text}"));
    let headers: Vec<(&str, &str)> = authorization.map(|value| ("Authorization", value)).into_iter().collect();
    #[cfg(test)]
    let result = match state.http_sender.as_mut() {
        Some(send) => send("POST", url, Some(&text), &headers),
        None => request_with_headers("POST", url, Some(&text), &headers),
    };
    #[cfg(not(test))]
    let result = request_with_headers("POST", url, Some(&text), &headers);
    match result {
        Err(e) => eprintln!("egress {kind} to {url} failed: {e}"),
        // The ledger 503s when its durable store is down; silence here would
        // drop attestations/instructions without a trace.
        Ok((status, resp)) if status >= 300 => {
            eprintln!("egress {kind} to {url} returned {status}: {resp}");
        }
        Ok(_) => {}
    }
}

fn attest(state: &mut State, environment_id: &str, jurisdiction: &str, lifecycle: &str) {
    attest_with(state, environment_id, jurisdiction, lifecycle, None)
}

/// The abort path attests its fault reason; every entry carries the slice's
/// region so sovereignty is assertable from the ledger.
fn attest_with(
    state: &mut State,
    environment_id: &str,
    jurisdiction: &str,
    lifecycle: &str,
    fault: Option<&str>,
) {
    let mut pairs = vec![
        ("environment_id", json::s(environment_id)),
        ("lifecycle", json::s(lifecycle)),
        ("jurisdiction", json::s(jurisdiction)),
        ("region", json::s(&region())),
    ];
    if let Some(reason) = fault {
        pairs.push(("fault", json::s(reason)));
    }
    let payload = json::obj(pairs);
    post_out(
        state,
        "attestation",
        &format!("{}/v1/attestations", ledger_url()),
        &payload,
        ledger_write_authorization().as_deref(),
    );
    let mut telemetry_pairs = vec![
        ("environment_id", json::s(environment_id)),
        ("event", json::s(lifecycle)),
        ("region", json::s(&region())),
    ];
    if let Some(reason) = fault {
        telemetry_pairs.push(("fault", json::s(reason)));
    }
    let telemetry = json::obj(telemetry_pairs);
    post_out(
        state,
        "telemetry",
        &format!("{}/v1/telemetry", resource_url()),
        &telemetry,
        None,
    );
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/environments") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let jurisdiction = body.str_of("jurisdiction").unwrap_or("").to_string();
            let envelope = match body.str_of("envelope") {
                Some(e) => e.to_string(),
                None => return Response::error(400, "envelope required"),
            };
            // The dispatcher's closing policy can only narrow the sealed one:
            // "manual" returns a shortlist even for an auto-close need. Any
            // other value is refused before an environment exists, so nothing
            // is attested for it.
            let manual = match body.get("policy") {
                None => false,
                Some(policy) if policy.as_str() == Some("manual") => true,
                Some(_) => return Response::problem_detail(400, "invalid_request", "policy must be \"manual\" when present"),
            };
            let empty = Vec::new();
            let offers = body.get("offers").and_then(|o| o.as_arr()).unwrap_or(&empty).clone();
            // s005.attribution: campaigns for this region travel INTO the
            // environment; the creative is rendered here, never outside.
            let campaigns = body.get("campaigns").and_then(|c| c.as_arr()).unwrap_or(&empty).clone();

            let environment_id = sha256::hex_digest(
                format!("{envelope}|{}|{}", now_nanos(), process_nonce()).as_bytes(),
            );
            attest(state, &environment_id, &jurisdiction, "created");
            attest(state, &environment_id, &jurisdiction, "attested");

            // Armed isolation fault (s004.failover): self-terminate BEFORE
            // the envelope is opened - partial state is destroyed with the
            // environment, the abort and its reason are attested, and no
            // match record exists to emit.
            if state.armed_faults > 0 {
                state.armed_faults -= 1;
                attest_with(state, &environment_id, &jurisdiction, "aborted", Some("isolation"));
                attest(state, &environment_id, &jurisdiction, "destroyed");
                return Response::json(
                    503,
                    &json::obj(vec![
                        ("status", json::s("aborted")),
                        ("environment_id", json::s(&environment_id)),
                        ("fault", json::s("isolation")),
                    ]),
                );
            }

            // The envelope is opened only inside this environment.
            let need = match json::parse(&envelope) {
                Ok(n) => n,
                Err(e) => {
                    // A fault reason on every abort keeps the incident schema
                    // uniform for the operator queue.
                    attest_with(state, &environment_id, &jurisdiction, "aborted", Some("bad-envelope"));
                    attest(state, &environment_id, &jurisdiction, "destroyed");
                    return Response::error(400, &format!("bad envelope: {e}"));
                }
            };

            if manual || need.bool_of("auto_close") != Some(true) {
                // Manual policy (s002.fitting), or a manual dispatch such as a
                // delegated need: the environment returns a shortlist of every
                // fully-fitting offer and commits NOTHING - no match id, no
                // settlement instruction, no order. The buyer's explicit booking
                // (for a delegated need, the coordinator's decision against the
                // mandate cap) is the only path to a commitment.
                // Only slots the need's fitting constraint allows may leave
                // the environment - the shortlist must honor EVERY constraint,
                // and the coordinator cannot re-check (it never parses the
                // sealed need).
                let before = need.i64_of("fitting_before_ordinal");
                // A campaign for this need's category boosts its offers with
                // Kai's creative (region already filtered by the coordinator).
                let campaign = campaigns
                    .iter()
                    .find(|c| c.str_of("category") == need.str_of("category"));
                let entries: Vec<json::Json> = offers
                    .iter()
                    .filter(|offer| qualifies(&need, offer))
                    .map(|offer| {
                        let allowed_slots: Vec<json::Json> = offer
                            .get("fitting_slots")
                            .and_then(|s| s.as_arr())
                            .map(|slots| {
                                slots
                                    .iter()
                                    .filter(|slot| match before {
                                        Some(b) => slot
                                            .i64_of("day_ordinal")
                                            .is_some_and(|d| d < b),
                                        None => true,
                                    })
                                    .cloned()
                                    .collect()
                            })
                            .unwrap_or_default();
                        let mut pairs = vec![
                            ("offer_id", json::s(offer.str_of("offer_id").unwrap_or(""))),
                            ("tenant", json::s(offer.str_of("tenant").unwrap_or(""))),
                            ("title", json::s(offer.str_of("title").unwrap_or(""))),
                            // The offer category equals the sealed need category
                            // (qualifies() requires it) - the coordinator uses
                            // it to enforce a mandate scope it cannot see.
                            ("category", json::s(offer.str_of("category").unwrap_or(""))),
                            ("price_cents", json::n(offer.i64_of("price_cents").unwrap_or(0))),
                            ("fitting_slots", json::arr(allowed_slots)),
                        ];
                        // Boosted presentation: the offer carries the campaign
                        // creative and the ad credit the booking will settle.
                        if let Some(c) = campaign {
                            let creative = c.str_of("creative").unwrap_or("");
                            state.ingress.push(format!(
                                "creative:{}:{creative}",
                                c.str_of("campaign_id").unwrap_or("")
                            ));
                            pairs.push((
                                "campaign",
                                json::obj(vec![
                                    ("campaign_id", json::s(c.str_of("campaign_id").unwrap_or(""))),
                                    ("asset_id", json::s(c.str_of("asset_id").unwrap_or(""))),
                                    ("creator", json::s(c.str_of("creator").unwrap_or(""))),
                                    ("creative", json::s(creative)),
                                    ("ad_cents", json::n(c.i64_of("ad_cents_per_match").unwrap_or(0))),
                                ]),
                            ));
                        }
                        json::obj(pairs)
                    })
                    .collect();
                let shortlist = json::obj(vec![
                    ("environment_id", json::s(&environment_id)),
                    ("shortlist", json::arr(entries)),
                    (
                        "need_context",
                        json::s(need.str_of("context").unwrap_or("")),
                    ),
                ]);
                state.egress.push(format!("shortlist-record:{}", shortlist.dump()));
                attest(state, &environment_id, &jurisdiction, "executed");
                attest(state, &environment_id, &jurisdiction, "destroyed");
                return Response::json(201, &shortlist);
            }

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
                ledger_write_authorization().as_deref(),
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
        ("POST", "/v1/faults") => {
            // Harness-only fault injection: arm the next N environments to
            // abort with an isolation fault.
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            if body.str_of("mode") != Some("isolation") {
                return Response::error(400, "mode 'isolation' required");
            }
            if body.get("count").is_some() && body.i64_of("count").is_none() {
                return Response::error(400, "count must be an integer");
            }
            let count = body.i64_of("count").unwrap_or(1);
            if !(0..=16).contains(&count) {
                return Response::error(400, "count must be 0..=16");
            }
            state.armed_faults = count;
            Response::json(200, &json::obj(vec![("armed", json::n(count))]))
        }
        ("GET", "/v1/egress") => {
            let entries: Vec<json::Json> =
                state.egress.iter().map(|e| json::s(e)).collect();
            Response::json(200, &json::obj(vec![("entries", json::arr(entries))]))
        }
        // Everything that entered an environment (s005: the campaign
        // creative). The buyer-signal-free counterpart of the egress log.
        ("GET", "/v1/ingress") => {
            let entries: Vec<json::Json> =
                state.ingress.iter().map(|e| json::s(e)).collect();
            Response::json(200, &json::obj(vec![("entries", json::arr(entries))]))
        }
        _ => Response::error(404, "not found"),
    }
}

fn main() -> std::io::Result<()> {
    // Not fatal: hand runs and cargo tests use a ledger with appends open. A
    // ledger that has a token refuses these appends with 401, which shows
    // only in each append's egress line, so the start names the cause once.
    if ledger_write_authorization().is_none() {
        eprintln!("slice-runtime: LEDGER_WRITE_TOKEN is not set; ledger appends go without a write token");
    }
    if let Some((resource, registration)) = advertisement() {
        std::thread::spawn(move || renew_lease(&resource, &registration));
    }
    serve_app(
        ServiceInfo {
            name: "slice-runtime",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            egress: Vec::new(),
            ingress: Vec::new(),
            armed_faults: 0,
            #[cfg(test)]
            http_sender: None,
        },
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

    fn dress_need() -> json::Json {
        json::parse(
            "{\"category\":\"dresses\",\"budget_cents\":20000,\"region\":\"region-a\",\"deadline_days\":4,\"auto_close\":false,\"attributes\":[\"midi\",\"sleeves\",\"warm-fabric\"],\"exclusions\":[\"dusty-blue\"],\"fitting_before_ordinal\":5,\"context\":\"midi dress, fitting before Friday\"}",
        )
        .unwrap()
    }

    fn dress_offer(attrs: &str, slot_ordinal: Option<i64>) -> json::Json {
        let slots = match slot_ordinal {
            Some(d) => format!(
                "[{{\"slot_id\":\"s1\",\"day\":\"thursday\",\"day_ordinal\":{d}}}]"
            ),
            None => String::from("[]"),
        };
        json::parse(&format!(
            "{{\"offer_id\":\"d1\",\"tenant\":\"elena-atelier\",\"title\":\"dress\",\"category\":\"dresses\",\"region\":\"region-a\",\"price_cents\":18000,\"deliver_by_days\":3,\"auto_close\":false,\"attributes\":{attrs},\"fitting_slots\":{slots}}}"
        ))
        .unwrap()
    }

    #[test]
    fn attribute_constraints_and_exclusions_gate_the_shortlist() {
        let n = dress_need();
        // Fully fitting: all required attributes, no excluded one, Thursday slot.
        assert!(qualifies(&n, &dress_offer("[\"midi\",\"sleeves\",\"warm-fabric\"]", Some(4))));
        // Excluded attribute (dusty-blue) disqualifies even when all else fits.
        assert!(!qualifies(
            &n,
            &dress_offer("[\"midi\",\"sleeves\",\"warm-fabric\",\"dusty-blue\"]", Some(4))
        ));
        // Missing a required attribute fails closed.
        assert!(!qualifies(&n, &dress_offer("[\"midi\",\"sleeves\"]", Some(4))));
        // No fitting slot before Friday (ordinal 5) fails the fitting constraint.
        assert!(!qualifies(&n, &dress_offer("[\"midi\",\"sleeves\",\"warm-fabric\"]", Some(6))));
        assert!(!qualifies(&n, &dress_offer("[\"midi\",\"sleeves\",\"warm-fabric\"]", None)));
    }

    #[test]
    fn s001_needs_state_no_attribute_constraints() {
        // The s001 need has no attributes/exclusions/fitting fields, so the
        // extended checks are vacuous and the base constraints still decide.
        let n = need();
        assert!(qualifies(&n, &offer(11000, "housewares", "region-a", 10, true)));
    }

    #[test]
    fn armed_environment_aborts_without_opening_the_envelope() {
        // The sender belongs to this state, so parallel tests cannot change
        // its peers or depend on an external resolver to reject a hostname.
        let attempts = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let recorded = attempts.clone();
        let mut state = State {
            egress: Vec::new(),
            ingress: Vec::new(),
            armed_faults: 1,
            http_sender: Some(Box::new(move |method, url, body, _| {
                recorded.lock().unwrap().push((method.to_string(), url.to_string(), body.unwrap().to_string()));
                Err(String::from("fixture peer unavailable"))
            })),
        };
        let response = handle(
            &mut state,
            &Request {
                method: "POST".to_string(),
                path: "/v1/environments".to_string(),
                headers: Vec::new(),
                body: "{\"jurisdiction\":\"region-a\",\"envelope\":\"{\\\"category\\\":\\\"housewares\\\"}\",\"offers\":[]}".to_string(),
            },
        );
        assert_eq!(response.status, 503);
        let body = json::parse(&response.body).unwrap();
        assert_eq!(body.str_of("status"), Some("aborted"));
        assert_eq!(body.str_of("fault"), Some("isolation"));
        assert!(body.str_of("environment_id").is_some());
        assert_eq!(state.armed_faults, 0, "the fault must be consumed");
        // Nothing need-derived leaves: the envelope was never opened, so no
        // match/shortlist record exists and the egress log holds only the
        // attestation/telemetry entries.
        let egress = state.egress.join("\n");
        assert!(!egress.contains("match-record"));
        assert!(!egress.contains("housewares"));
        assert!(!egress.contains("shortlist-record"));
        let attempts = attempts.lock().unwrap();
        assert_eq!(attempts.len(), 8, "every lifecycle attempts attestation and telemetry");
        for (index, lifecycle) in ["created", "attested", "aborted", "destroyed"].iter().enumerate() {
            for (offset, endpoint, field) in [(0, "/v1/attestations", "lifecycle"), (1, "/v1/telemetry", "event")] {
                let (method, url, payload) = &attempts[index * 2 + offset];
                assert_eq!(method, "POST");
                assert!(url.ends_with(endpoint), "{url}");
                let payload = json::parse(payload).unwrap();
                assert_eq!(payload.str_of(field), Some(*lifecycle));
                assert_eq!(payload.str_of("environment_id"), body.str_of("environment_id"));
                assert_eq!(payload.str_of("fault"), if *lifecycle == "aborted" { Some("isolation") } else { None });
                assert!(!payload.dump().contains("housewares"));
            }
        }
    }

    #[test]
    fn fault_arming_validates_mode_and_count() {
        let mut state = State {
            egress: Vec::new(),
            ingress: Vec::new(),
            armed_faults: 0,
            http_sender: None,
        };
        let req = |body: &str| Request {
            method: "POST".to_string(),
            path: "/v1/faults".to_string(),
            headers: Vec::new(),
            body: body.to_string(),
        };
        assert_eq!(handle(&mut state, &req("{\"mode\":\"chaos\"}")).status, 400);
        assert_eq!(handle(&mut state, &req("{\"mode\":\"isolation\",\"count\":99}")).status, 400);
        let ok = handle(&mut state, &req("{\"mode\":\"isolation\",\"count\":2}"));
        assert_eq!(ok.status, 200);
        assert_eq!(state.armed_faults, 2);
    }

    /// A state whose sender records every outbound URL and answers 201.
    fn recording_state() -> (State, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
        let sent = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let recorded = sent.clone();
        let state = State {
            egress: Vec::new(),
            ingress: Vec::new(),
            armed_faults: 0,
            http_sender: Some(Box::new(move |_, url, _, _| {
                recorded.lock().unwrap().push(url.to_string());
                Ok((201, String::from("{}")))
            })),
        };
        (state, sent)
    }

    /// An auto-close need with one offer it may close on, dispatched with
    /// `policy` as the body's policy member, if any.
    fn dispatch(state: &mut State, policy: Option<&str>) -> Response {
        let mut body = vec![
            ("jurisdiction", json::s("region-a")),
            ("envelope", json::s(&need().dump())),
            ("offers", json::arr(vec![offer(11000, "housewares", "region-a", 10, true)])),
        ];
        if let Some(policy) = policy {
            body.push(("policy", json::parse(policy).unwrap()));
        }
        handle(state, &Request {
            method: "POST".to_string(),
            path: "/v1/environments".to_string(),
            headers: Vec::new(),
            body: json::obj(body).dump(),
        })
    }

    #[test]
    fn manual_dispatch_policy_overrides_an_auto_close_envelope() {
        let (mut state, sent) = recording_state();
        let response = dispatch(&mut state, Some("\"manual\""));
        assert_eq!(response.status, 201, "{}", response.body);
        let body = json::parse(&response.body).unwrap();
        assert_eq!(body.get("shortlist").and_then(|s| s.as_arr()).map(Vec::len), Some(1), "{}", response.body);
        assert_eq!(body.str_of("match_id"), None);
        let sent = sent.lock().unwrap();
        assert_eq!(sent.len(), 8, "four lifecycle events, each attested and mirrored: {sent:?}");
        assert!(sent.iter().all(|url| url.ends_with("/v1/attestations") || url.ends_with("/v1/telemetry")), "{sent:?}");
        let egress = state.egress.join("\n");
        assert!(egress.contains("shortlist-record:"), "{egress}");
        assert!(!egress.contains("match-record:") && !egress.contains("settlement-instruction:"), "{egress}");
    }

    #[test]
    fn unknown_dispatch_policy_is_refused_before_an_environment_exists() {
        for policy in ["\"auto\"", "\"MANUAL\"", "\"\"", "null", "true"] {
            let (mut state, sent) = recording_state();
            let response = dispatch(&mut state, Some(policy));
            assert_eq!(response.status, 400, "{policy}: {}", response.body);
            assert_eq!(json::parse(&response.body).unwrap().str_of("code"), Some("invalid_request"), "{policy}");
            assert!(sent.lock().unwrap().is_empty(), "{policy}: nothing may be attested");
            assert!(state.egress.is_empty(), "{policy}");
        }
        // Without a policy the sealed need decides, as before: it closes.
        let (mut state, _) = recording_state();
        let closed = dispatch(&mut state, None);
        assert_eq!(closed.status, 201);
        assert!(json::parse(&closed.body).unwrap().str_of("match_id").is_some(), "{}", closed.body);
    }
}
