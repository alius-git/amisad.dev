// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC resource-svc: minimal carrier control plane. Registers edge
// slice endpoints per region with capacity, answers placement requests -
// DEFAULT allocation is capacity-greedy across ALL regions; a jurisdiction
// policy (s004.failover: Tom's sovereignty rules) restricts a jurisdiction
// to its compliant regions at allocation time, excluding roomier ones.
// Slice lifecycle telemetry is recorded, and every "aborted" event raises an
// incident in the operator queue.

use amisad_common::{json, serve_app, Request, Response, ServiceInfo};

struct Edge {
    region: String,
    endpoint: String,
    capacity: i64,
}

struct State {
    edges: Vec<Edge>,
    policies: Vec<(String, Vec<String>)>, // (jurisdiction, allowed regions)
    telemetry: Vec<json::Json>,
    incidents: Vec<json::Json>,
}

/// Allocation: the roomiest edge wins - unless a jurisdiction policy
/// restricts placement to its compliant regions.
fn place<'a>(
    edges: &'a [Edge],
    policies: &[(String, Vec<String>)],
    jurisdiction: &str,
) -> Option<&'a Edge> {
    let allowed = policies
        .iter()
        .find(|(j, _)| j == jurisdiction)
        .map(|(_, regions)| regions);
    edges
        .iter()
        .filter(|e| e.capacity > 0)
        .filter(|e| match allowed {
            Some(regions) => regions.contains(&e.region),
            None => true,
        })
        .max_by_key(|e| e.capacity)
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
            if body.get("capacity").is_some() && body.i64_of("capacity").is_none() {
                return Response::error(400, "capacity must be an integer");
            }
            let capacity = body.i64_of("capacity").unwrap_or(1);
            state.edges.retain(|e| e.region != region);
            state.edges.push(Edge {
                region: region.clone(),
                endpoint: endpoint.clone(),
                capacity,
            });
            Response::json(
                201,
                &json::obj(vec![
                    ("region", json::s(&region)),
                    ("endpoint", json::s(&endpoint)),
                    ("capacity", json::n(capacity)),
                ]),
            )
        }
        ("GET", "/v1/edges") => {
            let list: Vec<json::Json> = state
                .edges
                .iter()
                .map(|e| {
                    json::obj(vec![
                        ("region", json::s(&e.region)),
                        ("endpoint", json::s(&e.endpoint)),
                        ("capacity", json::n(e.capacity)),
                    ])
                })
                .collect();
            Response::json(200, &json::obj(vec![("edges", json::arr(list))]))
        }
        ("POST", "/v1/policies") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let jurisdiction = match body.str_of("jurisdiction") {
                Some(j) => j.to_string(),
                None => return Response::error(400, "jurisdiction required"),
            };
            let regions: Vec<String> = body
                .get("regions")
                .and_then(|r| r.as_arr())
                .map(|r| r.iter().filter_map(|s| s.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            if regions.is_empty() {
                return Response::error(400, "regions (non-empty array) required");
            }
            state.policies.retain(|(j, _)| *j != jurisdiction);
            state.policies.push((jurisdiction.clone(), regions.clone()));
            Response::json(
                201,
                &json::obj(vec![
                    ("jurisdiction", json::s(&jurisdiction)),
                    (
                        "regions",
                        json::arr(regions.iter().map(|r| json::s(r)).collect()),
                    ),
                ]),
            )
        }
        ("POST", "/v1/placements") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let jurisdiction = body.str_of("jurisdiction").unwrap_or("");
            if jurisdiction.is_empty() {
                return Response::error(400, "jurisdiction required");
            }
            match place(&state.edges, &state.policies, jurisdiction) {
                Some(edge) => Response::json(
                    200,
                    &json::obj(vec![
                        ("region", json::s(&edge.region)),
                        ("endpoint", json::s(&edge.endpoint)),
                    ]),
                ),
                None => Response::error(409, "no compliant edge with capacity for jurisdiction"),
            }
        }
        ("POST", "/v1/telemetry") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            // A terminated slice is an operator incident, not just a log line.
            if body.str_of("event") == Some("aborted") {
                state.incidents.push(body.clone());
            }
            state.telemetry.push(body);
            Response::json(200, &json::obj(vec![("recorded", json::b(true))]))
        }
        ("GET", "/v1/telemetry") => Response::json(
            200,
            &json::obj(vec![("entries", json::arr(state.telemetry.clone()))]),
        ),
        ("GET", "/v1/incidents") => Response::json(
            200,
            &json::obj(vec![("incidents", json::arr(state.incidents.clone()))]),
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
            policies: Vec::new(),
            telemetry: Vec::new(),
            incidents: Vec::new(),
        },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edges() -> Vec<Edge> {
        vec![
            Edge {
                region: "region-a".to_string(),
                endpoint: "http://edge-a:8080".to_string(),
                capacity: 2,
            },
            Edge {
                region: "region-b".to_string(),
                endpoint: "http://edge-b:8080".to_string(),
                capacity: 10,
            },
        ]
    }

    #[test]
    fn default_placement_is_capacity_greedy_across_regions() {
        let edges = edges();
        let hit = place(&edges, &[], "region-a").expect("placement");
        assert_eq!(hit.endpoint, "http://edge-b:8080"); // roomier wins
    }

    #[test]
    fn jurisdiction_policy_excludes_the_roomier_region() {
        let edges = edges();
        let policies = vec![("region-a".to_string(), vec!["region-a".to_string()])];
        let hit = place(&edges, &policies, "region-a").expect("placement");
        assert_eq!(hit.endpoint, "http://edge-a:8080"); // compliant only
        // Other jurisdictions stay unrestricted.
        let free = place(&edges, &policies, "region-b").expect("placement");
        assert_eq!(free.endpoint, "http://edge-b:8080");
    }

    #[test]
    fn empty_policy_match_means_no_placement() {
        let edges = edges();
        let policies = vec![("region-x".to_string(), vec!["region-z".to_string()])];
        assert!(place(&edges, &policies, "region-x").is_none());
    }
}
