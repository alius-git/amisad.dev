// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC insights-svc: threshold-protected aggregate demand insights.
// s003.silence minimal slice: an aggregation cycle pulls the COUNT of
// consent-contributing open needs from the fabric (counts only - no
// identity, no need content ever reaches this service) and keeps the cycle
// history. The full insights pipeline (thresholds, outlooks, suppression)
// lands with s009.suppression.

use amisad_common::{json, request, serve_app, Request, Response, ServiceInfo};

struct State {
    cycles: Vec<i64>, // contributions per aggregation cycle, in run order
}

fn coordinator_url() -> String {
    std::env::var("COORDINATOR_URL")
        .unwrap_or_else(|_| String::from("http://fabric-coordinator:8080"))
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/aggregation/cycle") => {
            let contributions = match request(
                "GET",
                &format!("{}/v1/needs/contributions", coordinator_url()),
                None,
            ) {
                Ok((200, text)) => match json::parse(&text) {
                    Ok(c) => c.i64_of("contributions").unwrap_or(0),
                    Err(e) => return Response::error(502, &format!("bad contributions: {e}")),
                },
                Ok((status, _)) => {
                    return Response::error(502, &format!("contributions ({status})"))
                }
                Err(e) => return Response::error(503, &format!("fabric unavailable: {e}")),
            };
            state.cycles.push(contributions);
            Response::json(
                201,
                &json::obj(vec![
                    ("cycle", json::n(state.cycles.len() as i64)),
                    ("contributions", json::n(contributions)),
                ]),
            )
        }
        ("GET", "/v1/aggregates") => Response::json(
            200,
            &json::obj(vec![
                ("cycles", json::n(state.cycles.len() as i64)),
                (
                    "latest_contributions",
                    state
                        .cycles
                        .last()
                        .map(|c| json::n(*c))
                        .unwrap_or(json::Json::Null),
                ),
                (
                    "history",
                    json::arr(state.cycles.iter().map(|c| json::n(*c)).collect()),
                ),
            ]),
        ),
        _ => Response::error(404, "not found"),
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "insights-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State { cycles: Vec::new() },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aggregates_report_cycle_history_without_identity() {
        let mut state = State {
            cycles: vec![2, 0],
        };
        let response = handle(
            &mut state,
            &Request {
                method: "GET".to_string(),
                path: "/v1/aggregates".to_string(),
                body: String::new(),
            },
        );
        assert_eq!(response.status, 200);
        let body = json::parse(&response.body).unwrap();
        assert_eq!(body.i64_of("cycles"), Some(2));
        assert_eq!(body.i64_of("latest_contributions"), Some(0));
        for marker in ["maya", "subject", "need_context", "envelope"] {
            assert!(!response.body.contains(marker), "aggregate leaked: {marker}");
        }
    }
}
