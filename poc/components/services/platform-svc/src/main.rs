// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 4247c005-5d25-4bf6-b5de-8ab6b13da208
// AmisAd POC platform-svc: marketplace stewardship. s004.failover: cross-party
// incident cases linking environment lifecycles by id. s008.mediation: the
// support desk - a case opens carrying operational METADATA only (order state,
// settlement) with no buyer identity; a scoped, time-boxed disclosure artifact
// can be attached and read only until it expires, after which the access path
// is gone. Nothing buyer-derived ever reaches this service. Sam's refund goes
// through this desk to ledger-svc, which takes appends only with the write
// token this service holds. Opening, advancing, refunding and resolving a
// support case need Sam's identity-mock token; the coordinator's delivery of
// a disclosure grant needs that same write token as a bearer; reads stay open.

use amisad_common::{bearer_matches, json, post_to_ledger, request, serve_app, Request, Response, ServiceInfo};
use std::time::{SystemTime, UNIX_EPOCH};

struct SupportCase {
    id: String,
    match_id: String,
    metadata: json::Json,
    stage: String, // opened | disclosure-requested | disclosed | resolved
    artifact: Option<String>,
    disclosure_expiry: i64,
    lifecycle: Vec<json::Json>, // request -> grant -> delivery -> expiry
}

struct State {
    cases: Vec<json::Json>,
    support: Vec<SupportCase>,
    /// LEDGER_WRITE_TOKEN; None leaves the disclosure grant route open.
    write_token: Option<String>,
}

fn ledger_url() -> String {
    std::env::var("LEDGER_URL").unwrap_or_else(|_| String::from("http://ledger-svc:8080"))
}
fn identity_url() -> String {
    std::env::var("IDENTITY_URL").unwrap_or_else(|_| String::from("http://identity-mock:8080"))
}

/// The support desk's actor (s008.mediation): the only one who opens,
/// advances, refunds and resolves support cases.
const SUPPORT_AGENT: &str = "sam";

/// Verify the request's identity token with identity-mock, as
/// fabric-coordinator does for buyers, and require the support agent as its
/// actor: 401 when identity does not accept the token, 403 for another actor.
/// A route that names a case answers 404 for an unknown one first: case
/// records are readable without a token, so that answer reveals nothing.
fn verify_support_agent(body: &json::Json) -> Result<(), Response> {
    let verify_body = json::obj(vec![("token", json::s(body.str_of("token").unwrap_or("")))]).dump();
    match request("POST", &format!("{}/v1/verify", identity_url()), Some(&verify_body)) {
        Ok((200, text)) => match json::parse(&text) {
            Ok(v) if v.str_of("actor") == Some(SUPPORT_AGENT) => Ok(()),
            Ok(_) => Err(Response::problem(403, "support_agent_required")),
            Err(e) => Err(Response::problem_detail(502, "upstream_failed", &format!("bad identity: {e}"))),
        },
        Ok((status, _)) => Err(Response::problem_detail(401, "unverified_actor", &format!("identity answered {status}"))),
        Err(e) => Err(Response::problem_detail(503, "upstream_unavailable", &format!("identity unavailable: {e}"))),
    }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn support_json(c: &SupportCase) -> json::Json {
    // The case record: metadata + lifecycle only. No identity, no artifact
    // content (that is fetched separately and gated on expiry).
    json::obj(vec![
        ("case_id", json::s(&c.id)),
        ("match_id", json::s(&c.match_id)),
        ("metadata", c.metadata.clone()),
        ("stage", json::s(&c.stage)),
        ("lifecycle", json::arr(c.lifecycle.clone())),
    ])
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/incidents") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let summary = body.str_of("summary").unwrap_or("").to_string();
            let from = body.str_of("from").unwrap_or("").to_string();
            let raw_ids = body
                .get("environment_ids")
                .and_then(|e| e.as_arr())
                .cloned()
                .unwrap_or_default();
            let environment_ids: Vec<json::Json> = raw_ids
                .iter()
                .filter(|i| i.as_str().is_some())
                .cloned()
                .collect();
            // All-or-nothing: silently under-linking evidence is worse than
            // rejecting the escalation.
            if summary.is_empty()
                || from.is_empty()
                || environment_ids.is_empty()
                || environment_ids.len() != raw_ids.len()
            {
                return Response::error(
                    400,
                    "summary, from, and environment_ids (non-empty array of strings) required",
                );
            }
            let case_id = format!("case-{:04}", state.cases.len() + 1);
            let case = json::obj(vec![
                ("case_id", json::s(&case_id)),
                ("summary", json::s(&summary)),
                ("from", json::s(&from)),
                ("environment_ids", json::arr(environment_ids)),
                ("status", json::s("open")),
            ]);
            state.cases.push(case);
            Response::json(201, &json::obj(vec![("case_id", json::s(&case_id))]))
        }
        ("GET", "/v1/incidents") => Response::json(
            200,
            &json::obj(vec![("cases", json::arr(state.cases.clone()))]),
        ),
        // s008: a support case opens carrying operational metadata only.
        ("POST", "/v1/support/cases") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let match_id = match body.str_of("match_id") {
                Some(m) => m.to_string(),
                None => return Response::error(400, "match_id required"),
            };
            if let Err(resp) = verify_support_agent(&body) {
                return resp;
            }
            let metadata = body.get("metadata").cloned().unwrap_or(json::Json::Null);
            let id = format!("support-{:04}", state.support.len() + 1);
            state.support.push(SupportCase {
                id: id.clone(),
                match_id,
                metadata,
                stage: String::from("opened"),
                artifact: None,
                disclosure_expiry: 0,
                lifecycle: Vec::new(),
            });
            Response::json(201, &json::obj(vec![("case_id", json::s(&id))]))
        }
        // Sam requests a scoped disclosure for the case.
        ("POST", "/v1/support/cases/disclosure/request") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let case_id = body.str_of("case_id").unwrap_or("").to_string();
            let case = match state.support.iter_mut().find(|c| c.id == case_id) {
                Some(c) => c,
                None => return Response::error(404, "unknown case"),
            };
            if let Err(resp) = verify_support_agent(&body) {
                return resp;
            }
            case.stage = String::from("disclosure-requested");
            case.lifecycle.push(json::obj(vec![
                ("stage", json::s("request")),
                ("ts", json::n(now_secs())),
            ]));
            Response::json(200, &json::obj(vec![("case_id", json::s(&case_id)), ("stage", json::s("disclosure-requested"))]))
        }
        // Maya's grant delivers the artifact, scoped to this case and
        // time-boxed. The coordinator posts it after recording the consent;
        // that delivery acts for the buyer, not the support agent, so this
        // route takes the per-build write token both services hold, as a
        // bearer, instead of Sam's token. Without a configured token (unit
        // tests, hand runs) it stays open, like the ledger.
        ("POST", "/v1/support/cases/disclosure/grant") => {
            if let Some(token) = state.write_token.as_deref() {
                if !bearer_matches(token, req.header("authorization")) {
                    return Response::problem(401, "grant_token_required");
                }
            }
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let case_id = body.str_of("case_id").unwrap_or("").to_string();
            let artifact = body.str_of("artifact").unwrap_or("").to_string();
            let expiry_ts = body.i64_of("expiry_ts").unwrap_or(0);
            let case = match state.support.iter_mut().find(|c| c.id == case_id) {
                Some(c) => c,
                None => return Response::error(404, "unknown case"),
            };
            case.artifact = Some(artifact);
            case.disclosure_expiry = expiry_ts;
            case.stage = String::from("disclosed");
            case.lifecycle.push(json::obj(vec![("stage", json::s("grant")), ("ts", json::n(now_secs()))]));
            case.lifecycle.push(json::obj(vec![("stage", json::s("delivery")), ("ts", json::n(now_secs())), ("expiry_ts", json::n(expiry_ts))]));
            Response::json(200, &json::obj(vec![("case_id", json::s(&case_id)), ("stage", json::s("disclosed"))]))
        }
        // Sam refunds the case's match: the ledger posts compensating entries
        // referencing the case. The match is always the one recorded on the
        // case, never one from the body, and only Sam's token reaches the
        // ledger call, as for case creation. The ledger's answer is relayed as
        // it came, so an identical replay answers 200 with the prior outcome.
        ("POST", "/v1/support/cases/refund") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let case_id = body.str_of("case_id").unwrap_or("").to_string();
            let case = match state.support.iter().find(|c| c.id == case_id) {
                Some(c) => c,
                None => return Response::error(404, "unknown case"),
            };
            if let Err(resp) = verify_support_agent(&body) {
                return resp;
            }
            let adjustment = json::obj(vec![
                ("match_id", json::s(&case.match_id)),
                ("case_id", json::s(&case.id)),
            ]);
            match post_to_ledger(&format!("{}/v1/settlements/adjust", ledger_url()), &adjustment.dump()) {
                Ok((status, body)) => Response { status, body },
                Err(e) => Response::problem_detail(503, "upstream_unavailable", &format!("ledger unavailable: {e}")),
            }
        }
        ("POST", "/v1/support/cases/resolve") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let case_id = body.str_of("case_id").unwrap_or("").to_string();
            let case = match state.support.iter_mut().find(|c| c.id == case_id) {
                Some(c) => c,
                None => return Response::error(404, "unknown case"),
            };
            if let Err(resp) = verify_support_agent(&body) {
                return resp;
            }
            case.stage = String::from("resolved");
            Response::json(200, &json::obj(vec![("case_id", json::s(&case_id)), ("stage", json::s("resolved"))]))
        }
        _ => {
            if let ("GET", Some(case_id)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/incidents/"))
            {
                return match state
                    .cases
                    .iter()
                    .find(|c| c.str_of("case_id") == Some(case_id))
                {
                    Some(case) => Response::json(200, case),
                    None => Response::error(404, "unknown case"),
                };
            }
            // The disclosed artifact, read-only and gated on expiry: once the
            // grant lapses, the access path is gone (s008 TVP).
            if let ("GET", Some(rest)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/support/cases/"))
            {
                if let Some(case_id) = rest.strip_suffix("/disclosure") {
                    let case = match state.support.iter().find(|c| c.id == case_id) {
                        Some(c) => c,
                        None => return Response::error(404, "unknown case"),
                    };
                    return match &case.artifact {
                        Some(a) if now_secs() < case.disclosure_expiry => {
                            Response::json(200, &json::obj(vec![("artifact", json::s(a))]))
                        }
                        Some(_) => Response::error(410, "disclosure grant expired"),
                        None => Response::error(404, "no disclosure for case"),
                    };
                }
                if let Some(case) = state.support.iter().find(|c| c.id == rest) {
                    return Response::json(200, &support_json(case));
                }
                return Response::error(404, "unknown case");
            }
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    let write_token = std::env::var("LEDGER_WRITE_TOKEN").ok().filter(|token| !token.is_empty());
    serve_app(
        ServiceInfo {
            name: "platform-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State { cases: Vec::new(), support: Vec::new(), write_token },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(method: &str, path: &str, body: &str) -> Request {
        Request {
            method: method.to_string(),
            path: path.to_string(),
            headers: Vec::new(),
            body: body.to_string(),
        }
    }

    #[test]
    fn case_links_environment_lifecycles_and_rejects_empty() {
        let mut state = State { cases: Vec::new(), support: Vec::new(), write_token: None };
        let missing = handle(
            &mut state,
            &req("POST", "/v1/incidents", "{\"summary\":\"x\",\"from\":\"resource-ops\"}"),
        );
        assert_eq!(missing.status, 400);
        let opened = handle(
            &mut state,
            &req(
                "POST",
                "/v1/incidents",
                "{\"summary\":\"systemic isolation faults\",\"from\":\"resource-ops\",\"environment_ids\":[\"env-1\",\"env-2\"]}",
            ),
        );
        assert_eq!(opened.status, 201);
        let case_id = json::parse(&opened.body)
            .unwrap()
            .str_of("case_id")
            .unwrap()
            .to_string();
        let fetched = handle(&mut state, &req("GET", &format!("/v1/incidents/{case_id}"), ""));
        assert_eq!(fetched.status, 200);
        let case = json::parse(&fetched.body).unwrap();
        let ids: Vec<String> = case
            .get("environment_ids")
            .and_then(|e| e.as_arr())
            .unwrap()
            .iter()
            .filter_map(|i| i.as_str().map(str::to_string))
            .collect();
        assert_eq!(ids, vec!["env-1", "env-2"]);
        for marker in ["maya", "need", "envelope", "buyer"] {
            assert!(!fetched.body.contains(marker), "case leaked: {marker}");
        }
    }

    #[test]
    fn refund_needs_a_known_case() {
        let mut state = State { cases: Vec::new(), support: Vec::new(), write_token: None };
        // Answered before any ledger call: nothing listens on the default ledger host here.
        for body in ["{\"case_id\":\"support-0001\"}", "{}"] {
            assert_eq!(handle(&mut state, &req("POST", "/v1/support/cases/refund", body)).status, 404, "{body}");
        }
        assert_eq!(handle(&mut state, &req("POST", "/v1/support/cases/refund", "not json")).status, 400);
    }
}
