// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42aefdce-0ba0-40f1-b843-0d09e86de0c3
// AmisAd POC audit-svc: independent certification of the full evidence trail
// (s010.certification). Ingrid runs a certification that walks the ledger's
// raw chain dumps and re-verifies FOUR dimensions itself - attestation
// continuity, residency, consent, and settlement evidence - trusting no
// self-report from the ledger. It also localizes a deliberate tamper to the
// exact modified record. audit-svc NEVER writes to any ledger and reads no
// personal data; its own access log (all GETs) is the proof. In-memory (POC).

use amisad_common::{json, request, serve_app, sha256, Request, Response, ServiceInfo};

use std::collections::{HashMap, HashSet};

const GENESIS: &str = "0000000000000000000000000000000000000000000000000000000000000000";

struct State {
    access_log: Vec<json::Json>,
}

fn ledger_url() -> String {
    std::env::var("LEDGER_URL").unwrap_or_else(|_| String::from("http://ledger-svc:8080"))
}

/// A read of a ledger chain dump, recorded in the access log (method GET
/// only - read-only is the whole point). Returns the entries array.
fn read_chain(state: &mut State, path: &str) -> Result<Vec<json::Json>, Response> {
    state.access_log.push(json::obj(vec![
        ("method", json::s("GET")),
        ("target", json::s(path)),
    ]));
    match request("GET", &format!("{}{path}", ledger_url()), None) {
        Ok((200, text)) => match json::parse(&text) {
            Ok(b) => chain_entries(&b).ok_or_else(|| Response::problem(502, "invalid_chain")),
            Err(e) => Err(Response::error(502, &format!("bad chain dump: {e}"))),
        },
        Ok((status, _)) => Err(Response::error(502, &format!("chain read ({status})"))),
        Err(e) => Err(Response::error(503, &format!("ledger unavailable: {e}"))),
    }
}

/// A syntactically valid JSON value is not necessarily a ledger dump.
fn chain_entries(dump: &json::Json) -> Option<Vec<json::Json>> {
    let entries = dump.get("entries")?.as_arr()?;
    let head = dump.str_of("head")?;
    let hash_ok = |hash: &str| hash.len() == 64 && hash.bytes().all(|c| c.is_ascii_hexdigit());
    if !hash_ok(head) || entries.iter().any(|entry|
        !matches!(entry.get("payload"), Some(json::Json::Obj(_)))
        || !entry.str_of("prev").is_some_and(hash_ok)
        || !entry.str_of("hash").is_some_and(hash_ok)) {
        return None;
    }
    if head != entries.last().and_then(|entry| entry.str_of("hash")).unwrap_or(GENESIS) {
        return None;
    }
    Some(entries.clone())
}

/// Independently recompute a hash chain: genesis linkage, per-row
/// row_hash = sha256(prev_hash || canonical_payload), and prev/hash linkage.
/// Returns the count of rows that fail verification.
fn chain_violations(entries: &[json::Json]) -> i64 {
    let mut prev = GENESIS.to_string();
    let mut violations = 0;
    for e in entries {
        let entry_prev = e.str_of("prev").unwrap_or("");
        let entry_hash = e.str_of("hash").unwrap_or("");
        let payload = e.get("payload").cloned().unwrap_or(json::Json::Null);
        if entry_prev != prev {
            violations += 1;
        }
        let recomputed = sha256::hex_digest(format!("{entry_prev}{}", payload.dump()).as_bytes());
        if recomputed != entry_hash {
            violations += 1;
        }
        prev = entry_hash.to_string();
    }
    violations
}

/// Attestation continuity: every environment shows a complete lifecycle
/// created -> attested -> executed|aborted -> destroyed.
fn lifecycle_violations(entries: &[json::Json]) -> i64 {
    let mut environments: HashMap<&str, Vec<&str>> = HashMap::new();
    for entry in entries {
        let payload = entry.get("payload");
        let environment = payload.and_then(|p| p.str_of("environment_id")).unwrap_or("");
        let event = payload.and_then(|p| p.str_of("lifecycle")).unwrap_or("");
        environments.entry(environment).or_default().push(event);
    }
    // Certification is of completed environments; in-progress traces fail.
    environments.iter().filter(|(id, events)| id.is_empty()
        || !matches!(events.as_slice(), ["created", "attested", "executed" | "aborted", "destroyed"]))
        .count() as i64
}

/// Consent: replay the consent chain in order and check every "use" (the
/// coordinator's execution-time record that a consent was relied on) against
/// the grants and revokes before it. A buyer's own match needs participation
/// that was not revoked (absent history reads as granted, as at execution); a
/// delegated match needs an active, unexpired mandate whose category matches
/// and whose per-item cap holds unless the principal approved the match; a
/// disclosure needs an unexpired grant for that one case. Every settlement
/// instruction (one per match) must be backed by at least one participation or
/// mandate use: a retried commit records a use per attempt, each checked at
/// its own point in the chain, and an attempt that never committed leaves a
/// valid use with no instruction, which proves nothing wrong. Returns the
/// number of invalid uses plus the number of matches with no consent use.
fn consent_violations(entries: &[json::Json], instructions: &[json::Json]) -> i64 {
    let mut participation: HashMap<&str, &str> = HashMap::new();
    let mut mandates: HashMap<(&str, &str), Option<&json::Json>> = HashMap::new();
    let mut disclosures: HashMap<(&str, &str), Option<&json::Json>> = HashMap::new();
    let mut used: HashSet<&str> = HashSet::new();
    let mut violations = 0;
    for entry in entries {
        let Some(payload) = entry.get("payload") else { violations += 1; continue; };
        let subject = payload.str_of("subject").unwrap_or("");
        let ts = payload.i64_of("ts").unwrap_or(i64::MAX);
        let match_id = payload.str_of("match_id").unwrap_or("");
        let action = payload.str_of("action").unwrap_or("");
        match (payload.str_of("grant_type").unwrap_or(""), action) {
            ("participation", "grant" | "revoke") => { participation.insert(subject, action); }
            ("contribution", "grant" | "revoke") => {}
            ("mandate", "grant" | "revoke") => {
                let key = (subject, payload.str_of("delegate").unwrap_or(""));
                mandates.insert(key, (action == "grant").then_some(payload));
            }
            ("disclosure", "grant" | "revoke") => {
                let key = (subject, payload.str_of("scope").unwrap_or(""));
                disclosures.insert(key, (action == "grant").then_some(payload));
            }
            ("participation", "use") => {
                if match_id.is_empty() || participation.get(subject) == Some(&"revoke") { violations += 1; }
                else { used.insert(match_id); }
            }
            ("mandate", "use") => {
                let key = (subject, payload.str_of("delegate").unwrap_or(""));
                let via = payload.str_of("via").unwrap_or("");
                let price = payload.i64_of("price_cents");
                let valid = match mandates.get(&key) {
                    Some(Some(grant)) => grant.i64_of("expiry_ts").is_some_and(|expiry| ts < expiry)
                        && grant.str_of("category").is_some()
                        && grant.str_of("category") == payload.str_of("category")
                        && match via {
                            "approval" => price.is_some(),
                            "delegate" => price.zip(grant.i64_of("per_item_cents")).is_some_and(|(p, cap)| p <= cap),
                            _ => false,
                        },
                    _ => false,
                };
                if match_id.is_empty() || !valid { violations += 1; }
                else { used.insert(match_id); }
            }
            ("disclosure", "use") => {
                let key = (subject, payload.str_of("scope").unwrap_or(""));
                let valid = !key.1.is_empty() && matches!(disclosures.get(&key),
                    Some(Some(grant)) if grant.i64_of("expiry_ts").is_some_and(|expiry| ts <= expiry));
                if !valid { violations += 1; }
            }
            _ => violations += 1,
        }
    }
    violations + instructions.iter()
        .filter(|instruction| !used.contains(instruction.str_of("match_id").unwrap_or("")))
        .count() as i64
}

fn settlement_violations(entries: &[json::Json], instructions: &[json::Json]) -> i64 {
    let mut by_match: HashMap<&str, Vec<&json::Json>> = HashMap::new();
    for entry in entries {
        let Some(payload) = entry.get("payload") else { return 1; };
        let Some(id) = payload.str_of("match_id").filter(|id| !id.is_empty()) else { return 1; };
        by_match.entry(id).or_default().push(payload);
    }
    let mut seen = HashSet::new();
    let mut cases = HashMap::new();
    let mut violations = 0;
    for instruction in instructions {
        let id = instruction.str_of("match_id").unwrap_or("");
        if id.is_empty() || !seen.insert(id) { violations += 1; continue; }
        let Some(splits) = instruction.get("splits").and_then(|s| s.as_arr()) else { violations += 1; continue; };
        let mut expected = HashMap::new();
        let mut total = Some(0i64);
        let mut valid = true;
        for split in splits {
            match (split.str_of("party"), split.i64_of("amount_cents")) {
                (Some(party), Some(amount)) if amount >= 0 => {
                    if expected.insert(party, amount).is_some() { valid = false; }
                    total = total.and_then(|sum| sum.checked_add(amount));
                },
                _ => valid = false,
            }
        }
        let parties: &[&str] = if expected.contains_key("agency") {
            &["seller", "network", "platform", "agency", "creator"]
        } else { &["seller", "network", "platform", "ads"] };
        if expected.len() != parties.len() || parties.iter().any(|party| !expected.contains_key(party))
            || total.is_none() || total != instruction.i64_of("value_cents") { valid = false; }
        let rows = by_match.remove(id).unwrap_or_default();
        let mut paid = HashSet::new();
        let mut refunded = HashSet::new();
        let mut refund_case = None;
        for row in rows {
            let party = row.str_of("party").unwrap_or("");
            let Some(amount) = expected.get(party) else { valid = false; continue; };
            match row.str_of("entry_type") {
                None | Some("split") => {
                    if !refunded.is_empty() || !paid.insert(party) || row.i64_of("amount_cents") != Some(*amount) { valid = false; }
                },
                Some("adjustment") => {
                    let case = row.str_of("case_id").unwrap_or("");
                    if case.is_empty() || paid.len() != expected.len() || !refunded.insert(party)
                        || row.i64_of("amount_cents") != Some(-amount)
                        || refund_case.is_some_and(|previous| previous != case) { valid = false; }
                    if cases.insert(case, id).is_some_and(|previous| previous != id) { valid = false; }
                    refund_case = Some(case);
                },
                _ => valid = false,
            }
        }
        match instruction.bool_of("confirmed") {
            Some(true) if paid.len() == expected.len()
                && (refunded.is_empty() || refunded.len() == expected.len()) => {},
            Some(false) if paid.is_empty() && refunded.is_empty() => {},
            _ => valid = false,
        }
        if !valid { violations += 1; }
    }
    violations + by_match.len() as i64
}

fn read_instructions(state: &mut State) -> Result<Vec<json::Json>, Response> {
    let path = "/v1/settlements/instructions";
    state.access_log.push(json::obj(vec![("method", json::s("GET")), ("target", json::s(path))]));
    match request("GET", &format!("{}{path}", ledger_url()), None) {
        Ok((200, body)) => json::parse(&body).ok().and_then(|value|
            value.get("instructions").and_then(|items| items.as_arr()).cloned())
            .ok_or_else(|| Response::problem(502, "invalid_chain")),
        _ => Err(Response::problem(502, "invalid_chain")),
    }
}

fn dimension(name: &str, violations: i64) -> json::Json {
    json::obj(vec![
        ("dimension", json::s(name)),
        ("ok", json::b(violations == 0)),
        ("violations", json::n(violations)),
    ])
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/certify") => {
            let attest = match read_chain(state, "/v1/attestations") {
                Ok(e) => e,
                Err(r) => return r,
            };
            let settle = match read_chain(state, "/v1/settlements") {
                Ok(e) => e,
                Err(r) => return r,
            };
            let consent = match read_chain(state, "/v1/consents") {
                Ok(e) => e,
                Err(r) => return r,
            };

            let attestation_v = chain_violations(&attest) + lifecycle_violations(&attest);
            // Residency: every environment attests a region satisfying its
            // jurisdiction (POC: region present and equal to jurisdiction).
            let residency_v = attest
                .iter()
                .filter(|e| {
                    let p = e.get("payload");
                    let region = p.and_then(|p| p.str_of("region")).unwrap_or("");
                    let jur = p.and_then(|p| p.str_of("jurisdiction")).unwrap_or("");
                    region.is_empty() || region != jur
                })
                .count() as i64;
            let instructions = match read_instructions(state) {
                Ok(instructions) => instructions,
                Err(response) => return response,
            };
            // Consent: the chain is intact AND every match executed under a
            // consent that held at that point in the chain.
            let consent_v = chain_violations(&consent) + consent_violations(&consent, &instructions);
            let settlement_v = chain_violations(&settle) + settlement_violations(&settle, &instructions);

            let total = attestation_v + residency_v + consent_v + settlement_v;
            Response::json(
                200,
                &json::obj(vec![
                    ("attestation", dimension("attestation", attestation_v)),
                    ("residency", dimension("residency", residency_v)),
                    ("consent", dimension("consent", consent_v)),
                    ("settlement", dimension("settlement", settlement_v)),
                    ("total_violations", json::n(total)),
                    ("certified", json::b(total == 0)),
                ]),
            )
        }
        // Tamper check: the harness supplies a copy of the attestation entries
        // with one record modified; the auditor localizes it to the exact row.
        ("POST", "/v1/certify/tamper") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let entries = body.get("entries").and_then(|e| e.as_arr()).cloned().unwrap_or_default();
            let mut prev = GENESIS.to_string();
            let mut tampered: Option<i64> = None;
            for (i, e) in entries.iter().enumerate() {
                let entry_prev = e.str_of("prev").unwrap_or("");
                let entry_hash = e.str_of("hash").unwrap_or("");
                let payload = e.get("payload").cloned().unwrap_or(json::Json::Null);
                let recomputed =
                    sha256::hex_digest(format!("{entry_prev}{}", payload.dump()).as_bytes());
                if entry_prev != prev || recomputed != entry_hash {
                    tampered = Some(i as i64);
                    break;
                }
                prev = entry_hash.to_string();
            }
            Response::json(
                200,
                &json::obj(vec![
                    ("detected", json::b(tampered.is_some())),
                    ("tampered_index", tampered.map(json::n).unwrap_or(json::Json::Null)),
                ]),
            )
        }
        // The auditor's own access log: proof it only ever read (no writes,
        // no personal-data scope).
        ("GET", "/v1/access-log") => Response::json(
            200,
            &json::obj(vec![("access", json::arr(state.access_log.clone()))]),
        ),
        _ => Response::error(404, "not found"),
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "audit-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State { access_log: Vec::new() },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chain(payloads: &[json::Json]) -> Vec<json::Json> {
        // Build a valid hash chain the way ledger-svc does.
        let mut prev = GENESIS.to_string();
        let mut out = Vec::new();
        for p in payloads {
            let hash = sha256::hex_digest(format!("{prev}{}", p.dump()).as_bytes());
            out.push(json::obj(vec![
                ("payload", p.clone()),
                ("prev", json::s(&prev)),
                ("hash", json::s(&hash)),
            ]));
            prev = hash;
        }
        out
    }

    fn env_payloads() -> Vec<json::Json> {
        ["created", "attested", "executed", "destroyed"]
            .iter()
            .map(|l| {
                json::obj(vec![
                    ("environment_id", json::s("env-1")),
                    ("lifecycle", json::s(l)),
                    ("jurisdiction", json::s("region-a")),
                    ("region", json::s("region-a")),
                ])
            })
            .collect()
    }

    #[test]
    fn clean_chain_has_no_violations() {
        let c = chain(&env_payloads());
        assert_eq!(chain_violations(&c), 0);
        assert_eq!(lifecycle_violations(&c), 0);
    }

    #[test]
    fn tampered_payload_is_localized() {
        let mut c = chain(&env_payloads());
        // Modify the 3rd row's payload after the fact (a tamper).
        c[2] = json::obj(vec![
            ("payload", json::obj(vec![("environment_id", json::s("env-1")), ("lifecycle", json::s("EXECUTED-TAMPERED"))])),
            ("prev", json::s(c[2].str_of("prev").unwrap())),
            ("hash", json::s(c[2].str_of("hash").unwrap())),
        ]);
        let mut state = State { access_log: Vec::new() };
        let body = json::obj(vec![("entries", json::arr(c))]).dump();
        let resp = handle(&mut state, &Request {
            method: "POST".to_string(),
            path: "/v1/certify/tamper".to_string(),
            body,
        });
        let parsed = json::parse(&resp.body).unwrap();
        assert_eq!(parsed.bool_of("detected"), Some(true));
        assert_eq!(parsed.i64_of("tampered_index"), Some(2));
    }

    fn consent(subject: &str, grant_type: &str, action: &str, ts: i64, extra: Vec<(&str, json::Json)>) -> json::Json {
        let mut fields = vec![
            ("subject", json::s(subject)),
            ("grant_type", json::s(grant_type)),
            ("action", json::s(action)),
        ];
        fields.extend(extra);
        fields.push(("ts", json::n(ts)));
        json::obj(fields)
    }

    fn matched(id: &str) -> Vec<(&str, json::Json)> {
        vec![("match_id", json::s(id))]
    }

    fn instructions(ids: &[&str]) -> Vec<json::Json> {
        ids.iter().map(|id| json::obj(vec![("match_id", json::s(id))])).collect()
    }

    fn mandate_grant(ts: i64) -> json::Json {
        consent("maya", "mandate", "grant", ts, vec![
            ("delegate", json::s("pat")),
            ("category", json::s("housewares")),
            ("per_item_cents", json::n(14000)),
            ("expiry_ts", json::n(1000)),
        ])
    }

    fn mandate_use(ts: i64, id: &str, category: &str, price: i64, via: &str) -> json::Json {
        consent("maya", "mandate", "use", ts, vec![
            ("delegate", json::s("pat")),
            ("match_id", json::s(id)),
            ("category", json::s(category)),
            ("price_cents", json::n(price)),
            ("via", json::s(via)),
        ])
    }

    #[test]
    fn participation_use_holds_without_history_and_after_a_regrant() {
        let c = chain(&[
            consent("maya", "participation", "use", 1, matched("m1")),
            consent("maya", "participation", "grant", 2, vec![]),
            consent("maya", "participation", "revoke", 3, vec![]),
            consent("maya", "participation", "grant", 4, vec![]),
            consent("maya", "participation", "use", 5, matched("m2")),
        ]);
        assert_eq!(consent_violations(&c, &instructions(&["m1", "m2"])), 0);
    }

    #[test]
    fn a_match_inside_the_revocation_window_is_a_violation() {
        let c = chain(&[
            consent("maya", "participation", "revoke", 1, vec![]),
            consent("maya", "participation", "use", 2, matched("m1")),
            // Another subject's revoke does not affect Maya, and vice versa.
            consent("elena", "participation", "use", 3, matched("m2")),
        ]);
        // The use inside the window is invalid, and m1 is left without valid consent.
        assert_eq!(consent_violations(&c, &instructions(&["m1", "m2"])), 2);
    }

    #[test]
    fn every_instructed_match_needs_a_valid_use() {
        let one = chain(&[consent("maya", "participation", "use", 1, matched("m1"))]);
        // m2 has an instruction but no consent evidence.
        assert_eq!(consent_violations(&one, &instructions(&["m1", "m2"])), 1);
        // An attempt that never committed leaves a valid use and no instruction.
        assert_eq!(consent_violations(&one, &instructions(&[])), 0);
        // A retried commit records one use per attempt.
        let retried = chain(&[
            consent("maya", "participation", "use", 1, matched("m1")),
            consent("maya", "participation", "use", 2, matched("m1")),
        ]);
        assert_eq!(consent_violations(&retried, &instructions(&["m1"])), 0);
        // An invalid use does not back its match: one violation for the use
        // and one for the match left without valid consent.
        let after_revoke = chain(&[
            consent("maya", "participation", "revoke", 1, vec![]),
            consent("maya", "participation", "use", 2, matched("m1")),
        ]);
        assert_eq!(consent_violations(&after_revoke, &instructions(&["m1"])), 2);
        // A use that names no match proves nothing.
        let unnamed = chain(&[consent("maya", "participation", "use", 1, vec![])]);
        assert_eq!(consent_violations(&unnamed, &instructions(&[])), 1);
    }

    #[test]
    fn mandate_use_is_checked_against_scope_cap_expiry_and_revocation() {
        let ok = chain(&[
            mandate_grant(1),
            mandate_use(2, "m1", "housewares", 12000, "delegate"),
            // Over the per-item cap is in scope only when Maya approved it.
            mandate_use(3, "m2", "housewares", 15000, "approval"),
        ]);
        assert_eq!(consent_violations(&ok, &instructions(&["m1", "m2"])), 0);
        for (bad, why) in [
            (vec![mandate_grant(1), mandate_use(2, "m1", "housewares", 15000, "delegate")], "over cap"),
            (vec![mandate_grant(1), mandate_use(2, "m1", "dresses", 12000, "delegate")], "out of scope"),
            (vec![mandate_grant(1), mandate_use(1000, "m1", "housewares", 12000, "delegate")], "expired"),
            (vec![mandate_use(1, "m1", "housewares", 12000, "delegate")], "never granted"),
            (vec![
                mandate_grant(1),
                consent("maya", "mandate", "revoke", 2, vec![("delegate", json::s("pat"))]),
                mandate_use(3, "m1", "housewares", 12000, "delegate"),
            ], "revoked"),
        ] {
            // The invalid use, and m1 left without valid consent.
            assert_eq!(consent_violations(&chain(&bad), &instructions(&["m1"])), 2, "{why}");
        }
    }

    #[test]
    fn disclosure_use_must_stay_inside_its_case_and_window() {
        let grant = consent("maya", "disclosure", "grant", 1, vec![
            ("scope", json::s("case-1")),
            ("expiry_ts", json::n(10)),
        ]);
        let deliver = |ts: i64, scope: &str| consent("maya", "disclosure", "use", ts, vec![("scope", json::s(scope))]);
        assert_eq!(consent_violations(&chain(&[grant.clone(), deliver(2, "case-1")]), &[]), 0);
        assert_eq!(consent_violations(&chain(&[grant.clone(), deliver(2, "case-2")]), &[]), 1);
        assert_eq!(consent_violations(&chain(&[grant, deliver(11, "case-1")]), &[]), 1);
    }

    #[test]
    fn incomplete_lifecycle_is_flagged() {
        // Missing 'destroyed' -> one violation.
        let partial: Vec<json::Json> = ["created", "attested", "executed"]
            .iter()
            .map(|l| json::obj(vec![("environment_id", json::s("e")), ("lifecycle", json::s(l))]))
            .collect();
        let c = chain(&partial);
        assert_eq!(lifecycle_violations(&c), 1);
    }
}
