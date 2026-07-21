// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC fabric-coordinator: routes need envelopes to sealed slice
// environments and relays results. By construction this service NEVER parses
// the envelope - it is carried as an opaque string from the buyer to the
// environment; only the slice-runtime opens it. Manual-policy needs
// (s002.fitting) come back as a shortlist: nothing commits until the buyer
// books, and the coordinator is the buyer's only surface, so it also keeps
// the per-handle notification log the scenarios assert on.
// s003.silence: a need with no fitting offer stays OPEN; every execution is
// gated on the subject's participation consent (checked against ledger-svc
// at execution time, absent history = granted - the explicit revoke is the
// kill switch); a matching cycle re-serves open needs when a seller
// publishes an offer or the subject re-grants participation.

use amisad_common::{json, request, serve_app, sha256, splits_for, Request, Response, ServiceInfo};
use std::time::{SystemTime, UNIX_EPOCH};

struct Shortlist {
    handle: String,
    environment_id: String,
    need_context: String,
    entries: Vec<json::Json>,
    booked: bool,
}

struct OpenNeed {
    subject: String,
    jurisdiction: String,
    envelope: String, // opaque here, like everywhere upstream
    handle: String,
}

/// A delegated-authority mandate (s006.mandate): Maya (principal) grants Pat
/// (delegate) closing authority in a scope. Scope lives here; the immutable
/// grant/revoke history lives on the consent ledger.
struct Mandate {
    principal: String, // subject hash
    delegate: String,  // subject hash
    category: String,
    per_item_cents: i64,
    expiry_ts: i64,
    revoked: bool,
}

/// An over-cap match awaiting the principal's approval (s006 step 5): the
/// offer is chosen but NOTHING commits until Maya approves.
struct Held {
    handle: String,
    principal: String,
    delegate: String,
    environment_id: String,
    offer_id: String,
    tenant: String,
    price_cents: i64,
    need_context: String,
}

struct State {
    orders: Vec<(String, String)>, // (handle, match_id)
    shortlists: Vec<Shortlist>,
    notifications: Vec<(String, String)>, // (handle, kind), in delivery order
    open_needs: Vec<OpenNeed>,
    mandates: Vec<Mandate>,
    held: Vec<Held>,
    activity: Vec<(String, json::Json)>, // (principal subject, entry) - Maya's trail
}

fn identity_url() -> String {
    std::env::var("IDENTITY_URL").unwrap_or_else(|_| String::from("http://identity-mock:8080"))
}
fn resource_url() -> String {
    std::env::var("RESOURCE_URL").unwrap_or_else(|_| String::from("http://resource-svc:8080"))
}
fn seller_url() -> String {
    std::env::var("SELLER_URL").unwrap_or_else(|_| String::from("http://seller-svc:8080"))
}
fn ledger_url() -> String {
    std::env::var("LEDGER_URL").unwrap_or_else(|_| String::from("http://ledger-svc:8080"))
}
fn ads_url() -> String {
    std::env::var("ADS_URL").unwrap_or_else(|_| String::from("http://ads-svc:8080"))
}

fn handle_for(match_id: &str) -> String {
    sha256::hex_digest(format!("{match_id}|handle").as_bytes())[..16].to_string()
}

/// Pseudonymous consent subject: derived from the verified identity, stable
/// across tokens, and the only buyer key the consent ledger ever sees.
fn subject_for(actor: &str, class: &str) -> String {
    sha256::hex_digest(format!("{actor}|{class}|subject").as_bytes())[..16].to_string()
}

/// Stable handle for an open (not yet matched) need.
fn open_handle(subject: &str, envelope: &str) -> String {
    sha256::hex_digest(format!("{subject}|{envelope}|open").as_bytes())[..16].to_string()
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Verify the buyer token with identity and derive the pseudonymous subject.
fn verify_subject(token: &str) -> Result<String, Response> {
    let verify_body = json::obj(vec![("token", json::s(token))]).dump();
    match request(
        "POST",
        &format!("{}/v1/verify", identity_url()),
        Some(&verify_body),
    ) {
        Ok((200, text)) => match json::parse(&text) {
            Ok(v) => Ok(subject_for(
                v.str_of("actor").unwrap_or(""),
                v.str_of("class").unwrap_or(""),
            )),
            Err(e) => Err(Response::error(502, &format!("bad identity: {e}"))),
        },
        Ok(_) => Err(Response::error(401, "unverified actor")),
        Err(e) => Err(Response::error(503, &format!("identity unavailable: {e}"))),
    }
}

/// The execution-time consent check. Absent history reads as granted (signup
/// implies participation); only an explicit ledger revoke blocks matching.
fn consent_granted(subject: &str, grant_type: &str) -> Result<bool, Response> {
    match request(
        "GET",
        &format!("{}/v1/consents/subject/{subject}", ledger_url()),
        None,
    ) {
        Ok((200, text)) => match json::parse(&text) {
            // Fail CLOSED on anything unexpected: for a kill switch, only an
            // explicit granted/none may pass, not a missing field.
            Ok(c) => Ok(matches!(c.str_of(grant_type), Some("granted") | Some("none"))),
            Err(e) => Err(Response::error(502, &format!("bad consent state: {e}"))),
        },
        Ok((status, _)) => Err(Response::error(502, &format!("consent lookup ({status})"))),
        Err(e) => Err(Response::error(503, &format!("ledger unavailable: {e}"))),
    }
}

/// Same derivation the sealed environment uses for auto-closed matches, so a
/// manual booking's match id is coherent with the attestation trail of the
/// environment that produced its shortlist.
fn booking_match_id(environment_id: &str, offer_id: &str) -> String {
    sha256::hex_digest(format!("{environment_id}|{offer_id}").as_bytes())
}

/// Pseudonymous buyer-facing view of the seller-side order state.
fn buyer_status(seller_state: &str) -> &'static str {
    match seller_state {
        "committed" | "provisioning" => "in-progress",
        "fulfilled" | "settled" => "delivered",
        other => {
            let _ = other;
            "unknown"
        }
    }
}

/// One matching attempt for one opaque envelope: jurisdiction placement,
/// public catalog fetch, sealed dispatch, then commit - a shortlist is
/// delivered (manual policy) or an order is created (auto-close).
/// Ok(Some(response)) when something was delivered/committed, Ok(None) when
/// no offer fits (the need can stay open), Err(response) on infrastructure
/// errors. handle_override keeps an open need's handle stable across cycles.
fn attempt_match(
    state: &mut State,
    jurisdiction: &str,
    envelope: &str,
    handle_override: Option<&str>,
) -> Result<Option<json::Json>, Response> {
    // 1. Jurisdiction-compliant placement.
    let placement_body = json::obj(vec![("jurisdiction", json::s(jurisdiction))]).dump();
    let placement = match request(
        "POST",
        &format!("{}/v1/placements", resource_url()),
        Some(&placement_body),
    ) {
        Ok((200, text)) => match json::parse(&text) {
            Ok(p) => p,
            Err(e) => return Err(Response::error(502, &format!("bad placement: {e}"))),
        },
        Ok((status, _)) => return Err(Response::error(503, &format!("no placement ({status})"))),
        Err(e) => return Err(Response::error(503, &format!("resource unavailable: {e}"))),
    };
    let endpoint = placement.str_of("endpoint").unwrap_or("").to_string();

    // 2. Offers are public; fetch the jurisdiction's catalog.
    let offers = match request(
        "GET",
        &format!("{}/v1/offers/region/{jurisdiction}", seller_url()),
        None,
    ) {
        Ok((200, text)) => match json::parse(&text) {
            Ok(o) => o.get("offers").cloned().unwrap_or(json::arr(Vec::new())),
            Err(e) => return Err(Response::error(502, &format!("bad offers: {e}"))),
        },
        Ok((status, _)) => return Err(Response::error(502, &format!("offers ({status})"))),
        Err(e) => return Err(Response::error(503, &format!("seller unavailable: {e}"))),
    };

    // 3. Active campaigns for this region are public and travel in with the
    // offers (s005.attribution). The coordinator never sees the need category
    // (sealed), so the environment picks the campaign that fits.
    let campaigns = match request(
        "GET",
        &format!("{}/v1/campaigns/region/{jurisdiction}", ads_url()),
        None,
    ) {
        Ok((200, text)) => json::parse(&text)
            .ok()
            .and_then(|c| c.get("campaigns").cloned())
            .unwrap_or_else(|| json::arr(Vec::new())),
        // Ads are non-critical: a missing campaign feed just means no boost.
        _ => json::arr(Vec::new()),
    };

    // 4. The envelope, offers, and campaigns travel INTO the environment.
    let dispatch = json::obj(vec![
        ("jurisdiction", json::s(jurisdiction)),
        ("envelope", json::s(envelope)),
        ("offers", offers),
        ("campaigns", campaigns),
    ])
    .dump();
    // An aborted environment (isolation fault, s004.failover) retries
    // AUTOMATICALLY: a fresh environment in the same compliant placement, up
    // to three attempts total. Fail-safe is the environment's job; recovery
    // is the fabric's.
    let mut match_record = None;
    for attempt in 1..=3 {
        match request(
            "POST",
            &format!("{endpoint}/v1/environments"),
            Some(&dispatch),
        ) {
            Ok((201, text)) => match json::parse(&text) {
                Ok(m) => {
                    match_record = Some(m);
                    break;
                }
                Err(e) => return Err(Response::error(502, &format!("bad match record: {e}"))),
            },
            Ok((404, _)) => return Ok(None),
            Ok((503, body))
                if json::parse(&body)
                    .ok()
                    .and_then(|b| b.str_of("status").map(|s| s == "aborted"))
                    .unwrap_or(false) =>
            {
                if attempt < 3 {
                    eprintln!("environment aborted (attempt {attempt}); retrying in the same placement");
                }
            }
            Ok((status, body)) => {
                return Err(Response::error(502, &format!("environment ({status}): {body}")))
            }
            Err(e) => return Err(Response::error(503, &format!("slice unavailable: {e}"))),
        }
    }
    let match_record = match match_record {
        Some(m) => m,
        None => return Err(Response::error(502, "environment aborted repeatedly")),
    };

    // 4a. Manual policy: the environment returned a shortlist, not a match.
    // Deliver it (notification) and commit NOTHING - no seller order exists
    // until the buyer books.
    if let Some(entries) = match_record.get("shortlist").and_then(|s| s.as_arr()) {
        let environment_id = match_record.str_of("environment_id").unwrap_or("").to_string();
        let need_context = match_record.str_of("need_context").unwrap_or("").to_string();
        let entries = entries.clone();
        let handle = handle_override
            .map(str::to_string)
            .unwrap_or_else(|| handle_for(&environment_id));
        let response = json::obj(vec![
            ("handle", json::s(&handle)),
            ("environment_id", json::s(&environment_id)),
            ("shortlist", json::arr(entries.clone())),
        ]);
        state.shortlists.push(Shortlist {
            handle: handle.clone(),
            environment_id,
            need_context,
            entries,
            booked: false,
        });
        state.notifications.push((handle, String::from("shortlist")));
        return Ok(Some(response));
    }

    // 4b. Committed order to the seller: need context only, no identity.
    let match_id = match_record.str_of("match_id").unwrap_or("").to_string();
    let offer = match_record.get("offer").cloned().unwrap_or(json::Json::Null);
    let order_body = json::obj(vec![
        ("match_id", json::s(&match_id)),
        ("offer_id", json::s(offer.str_of("offer_id").unwrap_or(""))),
        ("tenant", json::s(offer.str_of("tenant").unwrap_or(""))),
        (
            "need_context",
            json::s(match_record.str_of("need_context").unwrap_or("")),
        ),
    ])
    .dump();
    match request(
        "POST",
        &format!("{}/v1/orders", seller_url()),
        Some(&order_body),
    ) {
        Ok((201, _)) => {}
        Ok((status, body)) => {
            return Err(Response::error(502, &format!("order create ({status}): {body}")))
        }
        Err(e) => return Err(Response::error(502, &format!("order create failed: {e}"))),
    }

    let handle = handle_override
        .map(str::to_string)
        .unwrap_or_else(|| handle_for(&match_id));
    state.orders.push((handle.clone(), match_id.clone()));
    state.notifications.push((handle.clone(), String::from("match")));
    Ok(Some(json::obj(vec![
        ("handle", json::s(&handle)),
        ("match_id", json::s(&match_id)),
        (
            "environment_id",
            json::s(match_record.str_of("environment_id").unwrap_or("")),
        ),
        ("offer", offer),
    ])))
}

/// A matching cycle over the open needs: consent-gated per subject, matched
/// needs leave the list, infrastructure errors keep the need open (a cycle
/// never drops a need). Returns how many needs matched.
fn run_cycle(state: &mut State) -> i64 {
    let mut matched = 0;
    let mut index = 0;
    while index < state.open_needs.len() {
        let (subject, jurisdiction, envelope, handle) = {
            let n = &state.open_needs[index];
            (
                n.subject.clone(),
                n.jurisdiction.clone(),
                n.envelope.clone(),
                n.handle.clone(),
            )
        };
        match consent_granted(&subject, "participation") {
            Ok(true) => {}
            Ok(false) => {
                index += 1;
                continue;
            }
            Err(resp) => {
                eprintln!("cycle: consent lookup failed ({}); need stays open", resp.status);
                index += 1;
                continue;
            }
        }
        match attempt_match(state, &jurisdiction, &envelope, Some(&handle)) {
            Ok(Some(_)) => {
                state.open_needs.remove(index);
                matched += 1;
            }
            Ok(None) => index += 1,
            Err(resp) => {
                eprintln!("cycle: match attempt failed ({}); need stays open", resp.status);
                index += 1;
            }
        }
    }
    matched
}

/// Record a consent-ledger entry (s006 mandates ride the same chain as buyer
/// consents). Returns the entry hash.
fn record_consent(entry: &json::Json) -> Result<String, Response> {
    match request(
        "POST",
        &format!("{}/v1/consents", ledger_url()),
        Some(&entry.dump()),
    ) {
        Ok((201, text)) => Ok(json::parse(&text)
            .ok()
            .and_then(|r| r.str_of("hash").map(|h| h.to_string()))
            .unwrap_or_default()),
        Ok((status, body)) => Err(Response::error(502, &format!("consent record ({status}): {body}"))),
        Err(e) => Err(Response::error(503, &format!("ledger unavailable: {e}"))),
    }
}

/// Commit a delegated match: settlement instruction, seller order, dual
/// attribution on the principal's activity trail. `via` is "delegate" (Pat's
/// own authority) or "approval" (over-cap, closed by Maya). Returns match_id.
fn commit_delegated(
    state: &mut State,
    principal: &str,
    delegate: &str,
    environment_id: &str,
    offer_id: &str,
    tenant: &str,
    price_cents: i64,
    need_context: &str,
    via: &str,
) -> Result<String, Response> {
    let match_id = booking_match_id(environment_id, offer_id);
    let (seller, network, platform, ads) = splits_for(price_cents);
    let instruction = json::obj(vec![
        ("match_id", json::s(&match_id)),
        ("value_cents", json::n(price_cents)),
        (
            "splits",
            json::obj(vec![
                ("seller_cents", json::n(seller)),
                ("network_cents", json::n(network)),
                ("platform_cents", json::n(platform)),
                ("ads_cents", json::n(ads)),
            ]),
        ),
    ])
    .dump();
    match request(
        "POST",
        &format!("{}/v1/settlements/instructions", ledger_url()),
        Some(&instruction),
    ) {
        Ok((201, _)) => {}
        Ok((status, body)) => {
            return Err(Response::error(502, &format!("settlement instruction ({status}): {body}")))
        }
        Err(e) => return Err(Response::error(503, &format!("ledger unavailable: {e}"))),
    }
    let order_body = json::obj(vec![
        ("match_id", json::s(&match_id)),
        ("offer_id", json::s(offer_id)),
        ("tenant", json::s(tenant)),
        ("need_context", json::s(need_context)),
    ])
    .dump();
    match request(
        "POST",
        &format!("{}/v1/orders", seller_url()),
        Some(&order_body),
    ) {
        Ok((201, _)) => {}
        Ok((status, body)) => {
            return Err(Response::error(502, &format!("order create ({status}): {body}")))
        }
        Err(e) => return Err(Response::error(502, &format!("order create failed: {e}"))),
    }
    // Dual attribution on the principal's trail: actor, principal, mandate ref.
    state.activity.push((
        principal.to_string(),
        json::obj(vec![
            ("kind", json::s("delegated-match")),
            ("actor", json::s(delegate)),
            ("principal", json::s(principal)),
            ("mandate", json::b(true)),
            ("via", json::s(via)),
            ("match_id", json::s(&match_id)),
        ]),
    ));
    Ok(match_id)
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/needs") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let token = body.str_of("token").unwrap_or("");
            let jurisdiction = body.str_of("jurisdiction").unwrap_or("").to_string();
            // Opaque: read as a string, never parsed here.
            let envelope = match body.str_of("envelope") {
                Some(e) => e.to_string(),
                None => return Response::error(400, "envelope required"),
            };

            // Verified subscriber only, then the execution-time consent gate:
            // no sealed environment is ever created for a revoked subject.
            let subject = match verify_subject(token) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            match consent_granted(&subject, "participation") {
                Ok(true) => {}
                Ok(false) => {
                    return Response::json(
                        403,
                        &json::obj(vec![
                            ("status", json::s("refused")),
                            ("reason", json::s("participation revoked")),
                        ]),
                    )
                }
                Err(resp) => return resp,
            }

            match attempt_match(state, &jurisdiction, &envelope, None) {
                Ok(Some(response)) => {
                    // A direct match satisfies any earlier open registration
                    // of the same need - drop it, or a later cycle would
                    // re-match it into a duplicate order.
                    let handle = open_handle(&subject, &envelope);
                    state.open_needs.retain(|n| n.handle != handle);
                    Response::json(201, &response)
                }
                Ok(None) => {
                    // No fitting offer today: the need stays open and will be
                    // re-served by a later matching cycle.
                    let handle = open_handle(&subject, &envelope);
                    if !state.open_needs.iter().any(|n| n.handle == handle) {
                        state.open_needs.push(OpenNeed {
                            subject,
                            jurisdiction,
                            envelope,
                            handle: handle.clone(),
                        });
                    }
                    Response::json(
                        201,
                        &json::obj(vec![
                            ("handle", json::s(&handle)),
                            ("status", json::s("open")),
                        ]),
                    )
                }
                Err(resp) => resp,
            }
        }
        ("POST", "/v1/consents") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let token = body.str_of("token").unwrap_or("");
            let grant_type = body.str_of("grant_type").unwrap_or("").to_string();
            let action = body.str_of("action").unwrap_or("").to_string();
            if !matches!(grant_type.as_str(), "participation" | "contribution")
                || !matches!(action.as_str(), "grant" | "revoke")
            {
                return Response::error(
                    400,
                    "grant_type (participation|contribution) and action (grant|revoke) required",
                );
            }
            let subject = match verify_subject(token) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            let ts = now_secs();
            let entry = json::obj(vec![
                ("subject", json::s(&subject)),
                ("grant_type", json::s(&grant_type)),
                ("action", json::s(&action)),
                ("ts", json::n(ts)),
            ])
            .dump();
            let hash = match request(
                "POST",
                &format!("{}/v1/consents", ledger_url()),
                Some(&entry),
            ) {
                Ok((201, text)) => match json::parse(&text)
                    .ok()
                    .and_then(|r| r.str_of("hash").map(|h| h.to_string()))
                {
                    Some(h) => h,
                    None => return Response::error(502, "consent record unreadable"),
                },
                Ok((status, body)) => {
                    return Response::error(502, &format!("consent record ({status}): {body}"))
                }
                Err(e) => return Response::error(503, &format!("ledger unavailable: {e}")),
            };
            // Re-granting participation re-serves the open needs immediately:
            // resumption IS a matching cycle.
            let mut rematched = 0;
            if grant_type == "participation" && action == "grant" {
                rematched = run_cycle(state);
            }
            Response::json(
                201,
                &json::obj(vec![
                    ("subject", json::s(&subject)),
                    ("grant_type", json::s(&grant_type)),
                    ("action", json::s(&action)),
                    ("ts", json::n(ts)),
                    ("hash", json::s(&hash)),
                    ("rematched", json::n(rematched)),
                ]),
            )
        }
        ("POST", "/v1/consents/state") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let subject = match verify_subject(body.str_of("token").unwrap_or("")) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            match request(
                "GET",
                &format!("{}/v1/consents/subject/{subject}", ledger_url()),
                None,
            ) {
                Ok((200, text)) => match json::parse(&text) {
                    Ok(c) => Response::json(200, &c),
                    Err(e) => Response::error(502, &format!("bad consent state: {e}")),
                },
                Ok((status, _)) => Response::error(502, &format!("consent lookup ({status})")),
                Err(e) => Response::error(503, &format!("ledger unavailable: {e}")),
            }
        }
        // s006.mandate: Maya grants Pat a scoped mandate. Recorded on the
        // consent ledger (immutable history) and held in memory (scope).
        ("POST", "/v1/mandates") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let principal = match verify_subject(body.str_of("token").unwrap_or("")) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            let delegate_actor = body.str_of("delegate").unwrap_or("");
            let category = body.str_of("category").unwrap_or("");
            let per_item_cents = body.i64_of("per_item_cents").unwrap_or(0);
            let expiry_ts = body.i64_of("expiry_ts").unwrap_or(now_secs() + 90 * 86400);
            if delegate_actor.is_empty() || category.is_empty() || per_item_cents <= 0 {
                return Response::error(400, "delegate, category, per_item_cents required");
            }
            let delegate = subject_for(delegate_actor, "person");
            let ts = now_secs();
            let entry = json::obj(vec![
                ("subject", json::s(&principal)),
                ("grant_type", json::s("mandate")),
                ("action", json::s("grant")),
                ("delegate", json::s(&delegate)),
                ("category", json::s(category)),
                ("per_item_cents", json::n(per_item_cents)),
                ("expiry_ts", json::n(expiry_ts)),
                ("ts", json::n(ts)),
            ]);
            let hash = match record_consent(&entry) {
                Ok(h) => h,
                Err(resp) => return resp,
            };
            state.mandates.retain(|m| !(m.principal == principal && m.delegate == delegate));
            state.mandates.push(Mandate {
                principal: principal.clone(),
                delegate: delegate.clone(),
                category: category.to_string(),
                per_item_cents,
                expiry_ts,
                revoked: false,
            });
            Response::json(
                201,
                &json::obj(vec![
                    ("principal", json::s(&principal)),
                    ("delegate", json::s(&delegate)),
                    ("category", json::s(category)),
                    ("per_item_cents", json::n(per_item_cents)),
                    ("hash", json::s(&hash)),
                ]),
            )
        }
        ("POST", "/v1/mandates/revoke") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let principal = match verify_subject(body.str_of("token").unwrap_or("")) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            let delegate = subject_for(body.str_of("delegate").unwrap_or(""), "person");
            let entry = json::obj(vec![
                ("subject", json::s(&principal)),
                ("grant_type", json::s("mandate")),
                ("action", json::s("revoke")),
                ("delegate", json::s(&delegate)),
                ("ts", json::n(now_secs())),
            ]);
            let hash = match record_consent(&entry) {
                Ok(h) => h,
                Err(resp) => return resp,
            };
            for m in state.mandates.iter_mut() {
                if m.principal == principal && m.delegate == delegate {
                    m.revoked = true;
                }
            }
            Response::json(
                201,
                &json::obj(vec![("revoked", json::b(true)), ("hash", json::s(&hash))]),
            )
        }
        // Pat's delegate workspace: the principals + scope he can still act
        // under (empty immediately after revocation).
        ("POST", "/v1/delegate/workspace") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let delegate = match verify_subject(body.str_of("token").unwrap_or("")) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            let now = now_secs();
            let list: Vec<json::Json> = state
                .mandates
                .iter()
                .filter(|m| m.delegate == delegate && !m.revoked && m.expiry_ts > now)
                .map(|m| {
                    json::obj(vec![
                        ("principal", json::s(&m.principal)),
                        ("category", json::s(&m.category)),
                        ("per_item_cents", json::n(m.per_item_cents)),
                        ("expiry_ts", json::n(m.expiry_ts)),
                    ])
                })
                .collect();
            Response::json(200, &json::obj(vec![("principals", json::arr(list))]))
        }
        // Pat states a delegated need. Scope (declared category) is checked
        // BEFORE any environment; the per-item cap is checked at match time:
        // under cap closes on Pat's authority, over cap is HELD for Maya.
        ("POST", "/v1/delegate/needs") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let delegate = match verify_subject(body.str_of("token").unwrap_or("")) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            let principal = subject_for(body.str_of("principal").unwrap_or(""), "person");
            let category = body.str_of("category").unwrap_or("").to_string();
            let jurisdiction = body.str_of("jurisdiction").unwrap_or("").to_string();
            let envelope = match body.str_of("envelope") {
                Some(e) => e.to_string(),
                None => return Response::error(400, "envelope required"),
            };
            let now = now_secs();
            let mandate = state
                .mandates
                .iter()
                .find(|m| m.principal == principal && m.delegate == delegate);
            let (per_item, in_scope) = match mandate {
                Some(m) if !m.revoked && m.expiry_ts > now => (m.per_item_cents, m.category == category),
                // No mandate, revoked, or expired: nothing may happen.
                _ => {
                    return Response::json(
                        403,
                        &json::obj(vec![
                            ("status", json::s("refused")),
                            ("reason", json::s("no valid mandate")),
                        ]),
                    )
                }
            };
            // Out-of-scope category refuses at submission: zero environments,
            // zero ledger entries.
            if !in_scope {
                return Response::json(
                    403,
                    &json::obj(vec![
                        ("status", json::s("refused")),
                        ("reason", json::s("out of mandate scope")),
                    ]),
                );
            }
            // Manual dispatch so nothing auto-commits; the coordinator decides
            // commit-vs-hold from the matched price.
            let shortlist = match attempt_match(state, &jurisdiction, &envelope, None) {
                Ok(Some(r)) => r,
                Ok(None) => {
                    return Response::json(
                        201,
                        &json::obj(vec![("status", json::s("no-match"))]),
                    )
                }
                Err(resp) => return resp,
            };
            // The freshly pushed shortlist is the last one; take its cheapest
            // qualifying entry.
            let sl = state.shortlists.last().unwrap();
            let environment_id = sl.environment_id.clone();
            let need_context = sl.need_context.clone();
            let best = sl
                .entries
                .iter()
                .min_by_key(|e| e.i64_of("price_cents").unwrap_or(i64::MAX))
                .cloned();
            let _ = shortlist;
            let offer = match best {
                Some(o) => o,
                None => {
                    return Response::json(
                        201,
                        &json::obj(vec![("status", json::s("no-match"))]),
                    )
                }
            };
            let offer_id = offer.str_of("offer_id").unwrap_or("").to_string();
            let tenant = offer.str_of("tenant").unwrap_or("").to_string();
            let price_cents = offer.i64_of("price_cents").unwrap_or(0);
            if price_cents <= per_item {
                let match_id = match commit_delegated(
                    state, &principal, &delegate, &environment_id, &offer_id, &tenant,
                    price_cents, &need_context, "delegate",
                ) {
                    Ok(m) => m,
                    Err(resp) => return resp,
                };
                Response::json(
                    201,
                    &json::obj(vec![
                        ("status", json::s("committed")),
                        ("match_id", json::s(&match_id)),
                        ("via", json::s("delegate")),
                    ]),
                )
            } else {
                // Over cap: match permitted, closing WITHHELD for approval.
                let handle = handle_for(&format!("{environment_id}|{offer_id}"));
                state.held.push(Held {
                    handle: handle.clone(),
                    principal: principal.clone(),
                    delegate: delegate.clone(),
                    environment_id,
                    offer_id,
                    tenant,
                    price_cents,
                    need_context,
                });
                state.activity.push((
                    principal.clone(),
                    json::obj(vec![
                        ("kind", json::s("approval-requested")),
                        ("actor", json::s(&delegate)),
                        ("principal", json::s(&principal)),
                        ("handle", json::s(&handle)),
                    ]),
                ));
                Response::json(
                    201,
                    &json::obj(vec![
                        ("status", json::s("held-for-approval")),
                        ("handle", json::s(&handle)),
                    ]),
                )
            }
        }
        ("POST", "/v1/mandates/approve") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let principal = match verify_subject(body.str_of("token").unwrap_or("")) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            let handle = body.str_of("handle").unwrap_or("").to_string();
            let held_index = state
                .held
                .iter()
                .position(|h| h.handle == handle && h.principal == principal);
            let held = match held_index {
                Some(i) => state.held.remove(i),
                None => return Response::error(404, "no held match for this principal"),
            };
            let match_id = match commit_delegated(
                state, &held.principal, &held.delegate, &held.environment_id,
                &held.offer_id, &held.tenant, held.price_cents, &held.need_context, "approval",
            ) {
                Ok(m) => m,
                Err(resp) => return resp,
            };
            Response::json(
                201,
                &json::obj(vec![
                    ("status", json::s("committed")),
                    ("match_id", json::s(&match_id)),
                    ("via", json::s("approval")),
                ]),
            )
        }
        // Maya's activity trail: every delegated action attributed to her.
        ("POST", "/v1/activity") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let principal = match verify_subject(body.str_of("token").unwrap_or("")) {
                Ok(s) => s,
                Err(resp) => return resp,
            };
            let list: Vec<json::Json> = state
                .activity
                .iter()
                .filter(|(p, _)| *p == principal)
                .map(|(_, e)| e.clone())
                .collect();
            Response::json(200, &json::obj(vec![("activity", json::arr(list))]))
        }
        ("POST", "/v1/offers/published") => {
            // Event from seller-svc (fire-and-forget thread on its side): a
            // new offer may fit an open need - run a matching cycle. The
            // consent gate inside the cycle is what makes revocation SILENT.
            let rematched = run_cycle(state);
            Response::json(200, &json::obj(vec![("rematched", json::n(rematched))]))
        }
        ("GET", "/v1/needs/contributions") => {
            // Aggregate-insights feed (s003 minimal): the COUNT of open needs
            // whose subject still grants aggregate contribution. Counts only,
            // no identity, no need content.
            let mut contributions = 0i64;
            for need in &state.open_needs {
                match consent_granted(&need.subject, "contribution") {
                    Ok(true) => contributions += 1,
                    Ok(false) => {}
                    Err(resp) => return resp,
                }
            }
            Response::json(
                200,
                &json::obj(vec![("contributions", json::n(contributions))]),
            )
        }
        ("POST", "/v1/bookings") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let (handle, offer_id) = match (body.str_of("handle"), body.str_of("offer_id")) {
                (Some(h), Some(o)) => (h.to_string(), o.to_string()),
                _ => return Response::error(400, "handle, offer_id required"),
            };
            // slot_id is optional: a fitting need (s002) books an appointment;
            // a plain accept (s005) commits with no slot.
            let slot_id = body.str_of("slot_id").unwrap_or("").to_string();
            let index = match state.shortlists.iter().position(|s| s.handle == handle) {
                Some(i) => i,
                None => return Response::error(404, "unknown handle"),
            };
            if state.shortlists[index].booked {
                return Response::error(409, "already booked");
            }
            let (environment_id, need_context, entry) = {
                let sl = &state.shortlists[index];
                let entry = match sl
                    .entries
                    .iter()
                    .find(|e| e.str_of("offer_id") == Some(offer_id.as_str()))
                {
                    Some(e) => e.clone(),
                    None => return Response::error(404, "offer not on shortlist"),
                };
                (sl.environment_id.clone(), sl.need_context.clone(), entry)
            };
            // A requested slot must exist on the offer; no slot requested
            // means no appointment (fail closed only when one was asked for).
            let slot_day = if slot_id.is_empty() {
                String::new()
            } else {
                match entry
                    .get("fitting_slots")
                    .and_then(|s| s.as_arr())
                    .and_then(|slots| {
                        slots
                            .iter()
                            .find(|s| s.str_of("slot_id") == Some(slot_id.as_str()))
                            .and_then(|s| s.str_of("day").map(|d| d.to_string()))
                    }) {
                    Some(d) => d,
                    None => return Response::error(404, "slot not offered"),
                }
            };
            let tenant = entry.str_of("tenant").unwrap_or("").to_string();
            let price_cents = entry.i64_of("price_cents").unwrap_or(0);
            let match_id = booking_match_id(&environment_id, &offer_id);

            // The booking IS the commitment: settlement instruction first
            // (fail closed - no instruction, no order), then the seller order
            // with the appointment. Need context only, no identity.
            // seller/network/platform always come from the offer price.
            let (seller, network, platform, _ads) = splits_for(price_cents);
            // s005.attribution: a boosted offer carries campaign credit. The
            // ad commitment is advertiser money ON TOP of the price (seller
            // revenue unchanged), split agency/creator, and it decrements the
            // campaign budget on record.
            let campaign = entry.get("campaign");
            let ad_cents = campaign.and_then(|c| c.i64_of("ad_cents")).unwrap_or(0);
            let value_cents = price_cents + ad_cents;
            let splits = if ad_cents > 0 {
                let agency = ad_cents * 60 / 100;
                json::obj(vec![
                    ("seller_cents", json::n(seller)),
                    ("network_cents", json::n(network)),
                    ("platform_cents", json::n(platform)),
                    ("agency_cents", json::n(agency)),
                    ("creator_cents", json::n(ad_cents - agency)),
                ])
            } else {
                json::obj(vec![
                    ("seller_cents", json::n(seller)),
                    ("network_cents", json::n(network)),
                    ("platform_cents", json::n(platform)),
                    ("ads_cents", json::n(0)),
                ])
            };
            let instruction = json::obj(vec![
                ("match_id", json::s(&match_id)),
                ("value_cents", json::n(value_cents)),
                ("splits", splits),
            ])
            .dump();
            match request(
                "POST",
                &format!("{}/v1/settlements/instructions", ledger_url()),
                Some(&instruction),
            ) {
                Ok((201, _)) => {}
                Ok((status, body)) => {
                    return Response::error(502, &format!("settlement instruction ({status}): {body}"))
                }
                Err(e) => return Response::error(503, &format!("ledger unavailable: {e}")),
            }
            let order_body = json::obj(vec![
                ("match_id", json::s(&match_id)),
                ("offer_id", json::s(&offer_id)),
                ("tenant", json::s(&tenant)),
                ("need_context", json::s(&need_context)),
                ("slot_id", json::s(&slot_id)),
                ("slot_day", json::s(&slot_day)),
            ])
            .dump();
            match request(
                "POST",
                &format!("{}/v1/orders", seller_url()),
                Some(&order_body),
            ) {
                Ok((201, _)) => {}
                Ok((status, body)) => {
                    return Response::error(502, &format!("order create ({status}): {body}"))
                }
                Err(e) => return Response::error(502, &format!("order create failed: {e}")),
            }
            // Record ad attribution and decrement the campaign budget. The
            // settlement is already durable, so a failed attribution is
            // logged, not fatal (best-effort like the ledger->ads credit flow).
            if ad_cents > 0 {
                if let Some(c) = campaign {
                    let attribution = json::obj(vec![
                        ("campaign_id", json::s(c.str_of("campaign_id").unwrap_or(""))),
                        ("asset_id", json::s(c.str_of("asset_id").unwrap_or(""))),
                        ("match_id", json::s(&match_id)),
                    ])
                    .dump();
                    match request(
                        "POST",
                        &format!("{}/v1/attributions", ads_url()),
                        Some(&attribution),
                    ) {
                        Ok((201, _)) => {}
                        Ok((status, body)) => eprintln!("attribution ({status}): {body}"),
                        Err(e) => eprintln!("attribution failed: {e}"),
                    }
                }
            }
            state.shortlists[index].booked = true;
            state.orders.push((handle.clone(), match_id.clone()));
            state
                .notifications
                .push((handle.clone(), String::from("booking-confirmed")));
            let mut resp = vec![
                ("handle", json::s(&handle)),
                ("match_id", json::s(&match_id)),
                ("offer_id", json::s(&offer_id)),
                ("slot_id", json::s(&slot_id)),
                ("slot_day", json::s(&slot_day)),
                ("state", json::s("committed")),
            ];
            if ad_cents > 0 {
                resp.push(("boosted", json::b(true)));
            }
            Response::json(201, &json::obj(resp))
        }
        _ => {
            if let ("GET", Some(handle)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/notifications/"))
            {
                let list: Vec<json::Json> = state
                    .notifications
                    .iter()
                    .filter(|(h, _)| h == handle)
                    .map(|(_, kind)| json::obj(vec![("kind", json::s(kind))]))
                    .collect();
                return Response::json(
                    200,
                    &json::obj(vec![("notifications", json::arr(list))]),
                );
            }
            if let ("GET", Some(handle)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/orders/"))
            {
                let match_id = match state.orders.iter().find(|(h, _)| h == handle) {
                    Some((_, m)) => m.clone(),
                    None => return Response::error(404, "unknown handle"),
                };
                return match request(
                    "GET",
                    &format!("{}/v1/orders/match/{match_id}", seller_url()),
                    None,
                ) {
                    Ok((200, text)) => match json::parse(&text) {
                        Ok(order) => {
                            let seller_state = order.str_of("state").unwrap_or("unknown");
                            Response::json(
                                200,
                                &json::obj(vec![
                                    ("handle", json::s(handle)),
                                    ("status", json::s(buyer_status(seller_state))),
                                ]),
                            )
                        }
                        Err(e) => Response::error(502, &format!("bad order: {e}")),
                    },
                    Ok((status, _)) => Response::error(502, &format!("order lookup ({status})")),
                    Err(e) => Response::error(503, &format!("seller unavailable: {e}")),
                };
            }
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "fabric-coordinator",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            orders: Vec::new(),
            shortlists: Vec::new(),
            notifications: Vec::new(),
            open_needs: Vec::new(),
            mandates: Vec::new(),
            held: Vec::new(),
            activity: Vec::new(),
        },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_is_deterministic_and_short() {
        let a = handle_for("match-1");
        let b = handle_for("match-1");
        let c = handle_for("match-2");
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 16);
    }

    #[test]
    fn booking_match_id_matches_the_sealed_derivation() {
        // Must stay sha256("<environment_id>|<offer_id>") - the same formula
        // slice-runtime uses for auto-closed matches - so manual bookings
        // reference the producing environment coherently.
        let a = booking_match_id("env-1", "offer-1");
        let b = sha256::hex_digest("env-1|offer-1".as_bytes());
        assert_eq!(a, b);
        assert_ne!(a, booking_match_id("env-1", "offer-2"));
    }

    #[test]
    fn subject_is_pseudonymous_and_stable() {
        let a = subject_for("maya", "person");
        let b = subject_for("maya", "person");
        let c = subject_for("elena", "person");
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 16);
        // A hex digest prefix, so no actor-name fragment can survive in it.
        assert!(a.chars().all(|ch| ch.is_ascii_hexdigit()), "not a hex digest: {a}");
    }

    #[test]
    fn open_handle_is_stable_per_subject_and_envelope() {
        let a = open_handle("subj1", "{\"category\":\"dresses\"}");
        let b = open_handle("subj1", "{\"category\":\"dresses\"}");
        let c = open_handle("subj1", "{\"category\":\"decanters\"}");
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 16);
    }

    #[test]
    fn buyer_status_mapping() {
        assert_eq!(buyer_status("committed"), "in-progress");
        assert_eq!(buyer_status("provisioning"), "in-progress");
        assert_eq!(buyer_status("fulfilled"), "delivered");
        assert_eq!(buyer_status("settled"), "delivered");
        assert_eq!(buyer_status("weird"), "unknown");
    }
}
