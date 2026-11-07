// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42990467-4bd0-4417-8bd6-067247b5bd7b
// AmisAd POC resource-svc: minimal carrier control plane. Registers edge
// slice endpoints per region with capacity, answers placement requests -
// DEFAULT allocation is capacity-greedy across ALL regions; a jurisdiction
// policy (s004.failover: Tom's sovereignty rules) restricts a jurisdiction
// to its compliant regions at allocation time, excluding roomier ones.
// Slice lifecycle telemetry is recorded, and every "aborted" event raises an
// incident in the operator queue. An edge may register with a lease that it
// renews; a lapsed edge gets no placement. With DATABASE_URL set, policies
// write through to PostgreSQL first and reload on start: a jurisdiction with
// no policy is placed on any region, so a lost policy would fail open. Edges,
// telemetry and incidents stay in memory.

use amisad_common::{json, serve_app, Request, Response, ServiceInfo};
use postgres::Client;
use std::time::{Duration, Instant};
#[path = "../../../lib/amisad-common/src/database.rs"]
mod database;

struct Edge {
    region: String,
    endpoint: String,
    capacity: i64,
    // When a leased registration lapses unless renewed; None never lapses.
    expires_at: Option<Instant>,
}

struct State {
    edges: Vec<Edge>,
    policies: Vec<(String, Vec<String>)>, // (jurisdiction, allowed regions)
    telemetry: Vec<json::Json>,
    incidents: Vec<json::Json>,
    db: Option<Client>,
}

fn open_db() -> Option<Client> { database::open("resource-svc") }
fn store_error(db: &Client, what: &str, e: postgres::Error) -> Response {
    database::store_error("resource-svc", db, what, e)
}

/// A policy whose regions cannot be read keeps no region, so its jurisdiction
/// gets no placement until the policy is set again, rather than any region.
fn load_policies(db: &mut Client) -> Vec<(String, Vec<String>)> {
    db.query("SELECT jurisdiction, regions FROM resource.allocation_policies ORDER BY jurisdiction", &[])
        .unwrap_or_else(|e| {
            eprintln!("resource-svc: loading allocation policies failed: {e}");
            std::process::exit(1);
        })
        .iter()
        .map(|row| {
            let jurisdiction: String = row.get(0);
            let text: String = row.get(1);
            let regions = region_list(json::parse(&text).ok().as_ref());
            if regions.is_empty() {
                eprintln!("resource-svc: WARNING policy for {jurisdiction} has no usable regions ({text}); it places nothing");
            }
            (jurisdiction, regions)
        })
        .collect()
}

/// The region names in a JSON array, as POST /v1/policies and the store keep them.
fn region_list(value: Option<&json::Json>) -> Vec<String> {
    value
        .and_then(|r| r.as_arr())
        .map(|r| r.iter().filter_map(|s| s.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

/// Allocation: the roomiest edge whose lease holds at `now` wins - unless a
/// jurisdiction policy restricts placement to its compliant regions.
fn place<'a>(
    edges: &'a [Edge],
    policies: &[(String, Vec<String>)],
    jurisdiction: &str,
    now: Instant,
) -> Option<&'a Edge> {
    let allowed = policies
        .iter()
        .find(|(j, _)| j == jurisdiction)
        .map(|(_, regions)| regions);
    edges
        .iter()
        .filter(|e| e.capacity > 0)
        .filter(|e| e.expires_at.is_none_or(|at| now < at))
        .filter(|e| match allowed {
            Some(regions) => regions.contains(&e.region),
            None => true,
        })
        .max_by_key(|e| e.capacity)
}

/// Whole seconds left on a lease, rounded up, so 0 means lapsed.
fn lease_remaining_secs(expires_at: Instant, now: Instant) -> i64 {
    let left = expires_at.saturating_duration_since(now);
    (left.as_secs() + u64::from(left.subsec_nanos() > 0)) as i64
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/edges") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let (region, endpoint) = match (body.str_of("region"), body.str_of("endpoint")) {
                (Some(r), Some(e)) => (r.to_string(), e.to_string()),
                _ => return Response::problem_detail(400, "invalid_request", "region and endpoint required"),
            };
            if body.get("capacity").is_some() && body.i64_of("capacity").is_none() {
                return Response::problem_detail(400, "invalid_request", "capacity must be an integer");
            }
            let capacity = body.i64_of("capacity").unwrap_or(1);
            // A lease lapses unless the edge registers again within it; a
            // registration without one stays until it is replaced.
            let lease_secs = match body.get("lease_secs") {
                None => None,
                Some(value) => match value.as_i64() {
                    Some(secs @ 1..=3600) => Some(secs),
                    _ => return Response::problem_detail(400, "invalid_request", "lease_secs must be an integer from 1 to 3600"),
                },
            };
            state.edges.retain(|e| e.region != region);
            state.edges.push(Edge {
                region: region.clone(),
                endpoint: endpoint.clone(),
                capacity,
                expires_at: lease_secs.map(|secs| Instant::now() + Duration::from_secs(secs as u64)),
            });
            let mut registered = vec![
                ("region", json::s(&region)),
                ("endpoint", json::s(&endpoint)),
                ("capacity", json::n(capacity)),
            ];
            if let Some(secs) = lease_secs {
                registered.push(("lease_secs", json::n(secs)));
            }
            Response::json(201, &json::obj(registered))
        }
        ("GET", "/v1/edges") => {
            let now = Instant::now();
            let list: Vec<json::Json> = state
                .edges
                .iter()
                .map(|e| {
                    let mut edge = vec![
                        ("region", json::s(&e.region)),
                        ("endpoint", json::s(&e.endpoint)),
                        ("capacity", json::n(e.capacity)),
                    ];
                    if let Some(at) = e.expires_at {
                        edge.push(("lease_remaining_secs", json::n(lease_remaining_secs(at, now))));
                    }
                    json::obj(edge)
                })
                .collect();
            Response::json(200, &json::obj(vec![("edges", json::arr(list))]))
        }
        ("POST", "/v1/policies") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let jurisdiction = match body.str_of("jurisdiction") {
                Some(j) => j.to_string(),
                None => return Response::problem_detail(400, "invalid_request", "jurisdiction required"),
            };
            let regions = region_list(body.get("regions"));
            if regions.is_empty() {
                return Response::problem_detail(400, "invalid_request", "regions (non-empty array) required");
            }
            let listed = json::arr(regions.iter().map(|r| json::s(r)).collect());
            if let Some(db) = state.db.as_mut() {
                if let Err(e) = db.execute(
                    "INSERT INTO resource.allocation_policies (jurisdiction, regions) VALUES ($1, $2) \
                     ON CONFLICT (jurisdiction) DO UPDATE SET regions = EXCLUDED.regions",
                    &[&jurisdiction, &listed.dump()],
                ) {
                    return store_error(db, "policy store", e);
                }
            }
            state.policies.retain(|(j, _)| *j != jurisdiction);
            state.policies.push((jurisdiction.clone(), regions));
            Response::json(
                201,
                &json::obj(vec![
                    ("jurisdiction", json::s(&jurisdiction)),
                    ("regions", listed),
                ]),
            )
        }
        ("POST", "/v1/placements") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
            };
            let jurisdiction = body.str_of("jurisdiction").unwrap_or("");
            if jurisdiction.is_empty() {
                return Response::problem_detail(400, "invalid_request", "jurisdiction required");
            }
            match place(&state.edges, &state.policies, jurisdiction, Instant::now()) {
                Some(edge) => Response::json(
                    200,
                    &json::obj(vec![
                        ("region", json::s(&edge.region)),
                        ("endpoint", json::s(&edge.endpoint)),
                    ]),
                ),
                None => Response::problem(409, "no_compliant_edge"),
            }
        }
        ("POST", "/v1/telemetry") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(_) => return Response::problem(400, "invalid_request"),
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
        _ => Response::problem(404, "not_found"),
    }
}

fn main() -> std::io::Result<()> {
    let mut db = open_db();
    let policies = db.as_mut().map(load_policies).unwrap_or_default();
    serve_app(
        ServiceInfo {
            name: "resource-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            edges: Vec::new(),
            policies,
            telemetry: Vec::new(),
            incidents: Vec::new(),
            db,
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
                expires_at: None,
            },
            Edge {
                region: "region-b".to_string(),
                endpoint: "http://edge-b:8080".to_string(),
                capacity: 10,
                expires_at: None,
            },
        ]
    }

    #[test]
    fn default_placement_is_capacity_greedy_across_regions() {
        let edges = edges();
        let hit = place(&edges, &[], "region-a", Instant::now()).expect("placement");
        assert_eq!(hit.endpoint, "http://edge-b:8080"); // roomier wins
    }

    #[test]
    fn jurisdiction_policy_excludes_the_roomier_region() {
        let edges = edges();
        let policies = vec![("region-a".to_string(), vec!["region-a".to_string()])];
        let hit = place(&edges, &policies, "region-a", Instant::now()).expect("placement");
        assert_eq!(hit.endpoint, "http://edge-a:8080"); // compliant only
        // Other jurisdictions stay unrestricted.
        let free = place(&edges, &policies, "region-b", Instant::now()).expect("placement");
        assert_eq!(free.endpoint, "http://edge-b:8080");
    }

    #[test]
    fn empty_policy_match_means_no_placement() {
        let edges = edges();
        let policies = vec![("region-x".to_string(), vec!["region-z".to_string()])];
        assert!(place(&edges, &policies, "region-x", Instant::now()).is_none());
    }

    #[test]
    fn stored_regions_that_cannot_be_read_place_nothing() {
        let edges = edges();
        for text in ["not json", "", "{\"regions\":[\"region-b\"]}", "\"region-b\"", "[]", "[1,2]"] {
            let regions = region_list(json::parse(text).ok().as_ref());
            assert!(regions.is_empty(), "{text}");
            let policies = vec![("region-x".to_string(), regions)];
            assert!(place(&edges, &policies, "region-x", Instant::now()).is_none(), "{text}");
            assert!(place(&edges, &policies, "region-y", Instant::now()).is_some(), "{text}");
        }
    }

    #[test]
    fn place_skips_lapsed_leases() {
        let start = Instant::now();
        let mut edges = edges();
        edges[1].expires_at = Some(start + Duration::from_secs(30));
        let roomier = place(&edges, &[], "region-a", start + Duration::from_secs(29)).expect("placement");
        assert_eq!(roomier.endpoint, "http://edge-b:8080", "a lease still running places");
        let left = place(&edges, &[], "region-a", start + Duration::from_secs(30)).expect("placement");
        assert_eq!(left.endpoint, "http://edge-a:8080", "a lapsed lease does not");
        edges[0].expires_at = Some(start);
        assert!(place(&edges, &[], "region-a", start + Duration::from_secs(30)).is_none());
        assert_eq!(lease_remaining_secs(start + Duration::from_millis(29_001), start), 30);
        assert_eq!(lease_remaining_secs(start, start + Duration::from_secs(1)), 0);
    }

    fn state() -> State {
        State { edges: Vec::new(), policies: Vec::new(), telemetry: Vec::new(), incidents: Vec::new(), db: None }
    }

    fn post(state: &mut State, path: &str, body: &str) -> Response {
        handle(state, &Request {
            method: "POST".to_string(),
            path: path.to_string(),
            headers: Vec::new(),
            body: body.to_string(),
        })
    }

    #[test]
    fn registration_without_a_lease_never_lapses() {
        let mut state = state();
        let registered = post(&mut state, "/v1/edges", "{\"region\":\"region-a\",\"endpoint\":\"http://edge-a:8080\"}");
        assert_eq!(registered.status, 201, "{}", registered.body);
        assert!(!registered.body.contains("lease"), "{}", registered.body);
        let much_later = Instant::now() + Duration::from_secs(10 * 365 * 86400);
        assert!(place(&state.edges, &[], "region-a", much_later).is_some());
        // Registering again with a lease replaces the region's entry and leases it.
        let leased = post(&mut state, "/v1/edges", "{\"region\":\"region-a\",\"endpoint\":\"http://edge-a:8080\",\"lease_secs\":30}");
        assert_eq!(json::parse(&leased.body).unwrap().i64_of("lease_secs"), Some(30));
        assert_eq!(state.edges.len(), 1);
        assert!(place(&state.edges, &[], "region-a", much_later).is_none());
    }

    #[test]
    fn lease_seconds_must_be_a_bounded_integer() {
        let mut state = state();
        for lease in ["0", "3601", "-5", "1.5", "\"30\"", "null", "true"] {
            let body = format!("{{\"region\":\"region-a\",\"endpoint\":\"http://edge-a:8080\",\"lease_secs\":{lease}}}");
            let refused = post(&mut state, "/v1/edges", &body);
            assert_eq!(refused.status, 400, "{lease}");
            assert_eq!(json::parse(&refused.body).unwrap().str_of("code"), Some("invalid_request"), "{lease}");
        }
        assert!(state.edges.is_empty(), "a refused registration changes nothing");
        for lease in ["1", "3600"] {
            let body = format!("{{\"region\":\"region-a\",\"endpoint\":\"http://edge-a:8080\",\"lease_secs\":{lease}}}");
            assert_eq!(post(&mut state, "/v1/edges", &body).status, 201, "{lease}");
        }
    }
}
