// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC platform-svc: marketplace stewardship. s004.failover minimal
// slice: cross-party incident cases - a carrier operator escalates a
// systemic fault pattern and the case links the affected environment
// lifecycles (ids only; nothing need- or buyer-derived ever reaches this
// service). Registry and settlement oversight land with later scenarios.

use amisad_common::{json, serve_app, Request, Response, ServiceInfo};

struct State {
    cases: Vec<json::Json>,
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/incidents") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
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
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "platform-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State { cases: Vec::new() },
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
            body: body.to_string(),
        }
    }

    #[test]
    fn case_links_environment_lifecycles_and_rejects_empty() {
        let mut state = State { cases: Vec::new() };
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
}
