// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC resource-svc: minimal carrier control plane for s001.fulfillment.
// Registers edge slice endpoints per region, answers placement requests with
// the jurisdiction constraint enforced at allocation time, and records slice
// lifecycle telemetry.

use amisad_common::{json, serve_app, Request, Response, ServiceInfo};

struct State {
    edges: Vec<(String, String)>, // (region, endpoint)
    telemetry: Vec<json::Json>,
}

fn place(edges: &[(String, String)], jurisdiction: &str) -> Option<(String, String)> {
    edges
        .iter()
        .find(|(region, _)| region == jurisdiction)
        .cloned()
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/edges") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let (region, endpoint) = match (body.str_of("region"), body.str_of("endpoint")) {
                (Some(r), Some(e)) => (r.to_string(), e.to_string()),
                _ => return Response::error(400, "region and endpoint required"),
            };
            state.edges.retain(|(r, _)| *r != region);
            state.edges.push((region.clone(), endpoint.clone()));
            Response::json(
                201,
                &json::obj(vec![
                    ("region", json::s(&region)),
                    ("endpoint", json::s(&endpoint)),
                ]),
            )
        }
        ("GET", "/v1/edges") => {
            let list: Vec<json::Json> = state
                .edges
                .iter()
                .map(|(r, e)| json::obj(vec![("region", json::s(r)), ("endpoint", json::s(e))]))
                .collect();
            Response::json(200, &json::obj(vec![("edges", json::arr(list))]))
        }
        ("POST", "/v1/placements") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let jurisdiction = body.str_of("jurisdiction").unwrap_or("");
            match place(&state.edges, jurisdiction) {
                Some((region, endpoint)) => Response::json(
                    200,
                    &json::obj(vec![
                        ("region", json::s(&region)),
                        ("endpoint", json::s(&endpoint)),
                    ]),
                ),
                None => Response::error(409, "no edge capacity in jurisdiction"),
            }
        }
        ("POST", "/v1/telemetry") => {
            match json::parse(&req.body) {
                Ok(b) => state.telemetry.push(b),
                Err(e) => return Response::error(400, &e),
            }
            Response::json(200, &json::obj(vec![("recorded", json::b(true))]))
        }
        ("GET", "/v1/telemetry") => Response::json(
            200,
            &json::obj(vec![("entries", json::arr(state.telemetry.clone()))]),
        ),
        _ => Response::error(404, "not found"),
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "resource-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            edges: Vec::new(),
            telemetry: Vec::new(),
        },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placement_respects_jurisdiction() {
        let edges = vec![
            ("region-a".to_string(), "http://edge-a:8080".to_string()),
            ("region-b".to_string(), "http://edge-b:8080".to_string()),
        ];
        let hit = place(&edges, "region-a").expect("placement");
        assert_eq!(hit.1, "http://edge-a:8080");
        assert!(place(&edges, "region-c").is_none());
    }
}
