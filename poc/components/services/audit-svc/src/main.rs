// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC audit-svc: independent certification of the full evidence trail
// (s010.certification). Ingrid runs a certification that walks the ledger's
// raw chain dumps and re-verifies FOUR dimensions itself - attestation
// continuity, residency, consent, and settlement conservation - trusting no
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
            // Consent: chain integrity (grant->use->termination is the
            // ledger's newest-wins fold; here we certify the chain is intact).
            let consent_v = chain_violations(&consent);
            let instructions = match read_instructions(state) {
                Ok(instructions) => instructions,
                Err(response) => return response,
            };
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
