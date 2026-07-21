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
            Ok(b) => Ok(b.get("entries").and_then(|e| e.as_arr()).cloned().unwrap_or_default()),
            Err(e) => Err(Response::error(502, &format!("bad chain dump: {e}"))),
        },
        Ok((status, _)) => Err(Response::error(502, &format!("chain read ({status})"))),
        Err(e) => Err(Response::error(503, &format!("ledger unavailable: {e}"))),
    }
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
    let mut envs: Vec<(String, Vec<String>)> = Vec::new();
    for e in entries {
        let payload = e.get("payload");
        let env = payload.and_then(|p| p.str_of("environment_id")).unwrap_or("").to_string();
        let life = payload.and_then(|p| p.str_of("lifecycle")).unwrap_or("").to_string();
        match envs.iter_mut().find(|(id, _)| *id == env) {
            Some((_, v)) => v.push(life),
            None => envs.push((env, vec![life])),
        }
    }
    let mut violations = 0;
    for (_, life) in &envs {
        let has = |s: &str| life.iter().any(|l| l == s);
        let terminal_ok = has("executed") ^ has("aborted");
        if !(has("created") && has("attested") && has("destroyed") && terminal_ok) {
            violations += 1;
        }
    }
    violations
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

            // Attestation: chain integrity + complete lifecycles.
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
            // Settlement conservation: chain integrity + every adjustment is a
            // compensating entry referencing a support case.
            let settlement_chain_v = chain_violations(&settle);
            let adjustment_v = settle
                .iter()
                .filter(|e| {
                    let p = e.get("payload");
                    p.and_then(|p| p.str_of("entry_type")) == Some("adjustment")
                        && p.and_then(|p| p.str_of("case_id")).unwrap_or("").is_empty()
                })
                .count() as i64;
            let settlement_v = settlement_chain_v + adjustment_v;

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
                Err(e) => return Response::error(400, &e),
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
