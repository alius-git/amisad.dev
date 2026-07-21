// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC insights-svc: threshold-protected aggregate demand insights.
// s003.silence: an aggregation cycle pulls the COUNT of consent-contributing
// open needs from the fabric. s009.suppression: per (category, region) demand
// and supply are recorded; any aggregate below the anonymity threshold is
// SUPPRESSED - absent from the workbench, from every published outlook, and
// from the seller/ads views that consume them (never zeroed, indistinguishable
// from no data). Outlooks are versioned and immutable. Counts only - no
// identity, no need content ever reaches this service.

use amisad_common::{json, request, serve_app, Request, Response, ServiceInfo};

/// Anonymity threshold: an aggregate is published only at or above this count.
const THRESHOLD: i64 = 5;

struct Cell {
    category: String,
    region: String,
    needs: i64,
    offers: i64,
}

struct State {
    cycles: Vec<i64>, // contributions per aggregation cycle, in run order
    cells: Vec<Cell>,
    outlooks: Vec<(String, json::Json)>, // (version, published aggregates)
}

fn coordinator_url() -> String {
    std::env::var("COORDINATOR_URL")
        .unwrap_or_else(|_| String::from("http://fabric-coordinator:8080"))
}

/// The aggregates that clear the threshold, as published figures. Below-
/// threshold cells are omitted entirely - not zeroed.
fn published_aggregates(cells: &[Cell]) -> Vec<json::Json> {
    cells
        .iter()
        .filter(|c| c.needs >= THRESHOLD)
        .map(|c| {
            json::obj(vec![
                ("category", json::s(&c.category)),
                ("region", json::s(&c.region)),
                ("demand", json::n(c.needs)),
            ])
        })
        .collect()
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
        // s009: record a unit of demand (need) or supply (offer) per cell.
        ("POST", "/v1/insights/record") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let category = body.str_of("category").unwrap_or("").to_string();
            let region = body.str_of("region").unwrap_or("").to_string();
            let kind = body.str_of("kind").unwrap_or("need");
            if category.is_empty() || region.is_empty() {
                return Response::error(400, "category and region required");
            }
            let cell = match state
                .cells
                .iter_mut()
                .find(|c| c.category == category && c.region == region)
            {
                Some(c) => c,
                None => {
                    state.cells.push(Cell {
                        category: category.clone(),
                        region: region.clone(),
                        needs: 0,
                        offers: 0,
                    });
                    state.cells.last_mut().unwrap()
                }
            };
            match kind {
                "offer" => cell.offers += 1,
                _ => cell.needs += 1,
            }
            Response::json(200, &json::obj(vec![("recorded", json::b(true))]))
        }
        // Dana's workbench: only above-threshold aggregates appear; a
        // below-threshold cell shows no figure at all.
        ("GET", "/v1/workbench") => Response::json(
            200,
            &json::obj(vec![
                ("threshold", json::n(THRESHOLD)),
                ("aggregates", json::arr(published_aggregates(&state.cells))),
            ]),
        ),
        // Dana publishes a versioned, immutable outlook from the current
        // above-threshold aggregates.
        ("POST", "/v1/outlooks") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let version = match body.str_of("version") {
                Some(v) => v.to_string(),
                None => return Response::error(400, "version required"),
            };
            if state.outlooks.iter().any(|(v, _)| *v == version) {
                return Response::error(409, "outlook version already published");
            }
            let outlook = json::obj(vec![
                ("version", json::s(&version)),
                ("aggregates", json::arr(published_aggregates(&state.cells))),
            ]);
            state.outlooks.push((version.clone(), outlook.clone()));
            Response::json(201, &outlook)
        }
        // Ecosystem health: above-threshold cells where needs outnumber
        // offers, flagged by category and region ONLY (no figures). The
        // threshold applies here too - a below-threshold cell surfaces
        // nowhere, not even as an unmet-demand flag.
        ("GET", "/v1/unmet-demand") => {
            let flags: Vec<json::Json> = state
                .cells
                .iter()
                .filter(|c| c.needs >= THRESHOLD && c.needs > c.offers)
                .map(|c| {
                    json::obj(vec![
                        ("category", json::s(&c.category)),
                        ("region", json::s(&c.region)),
                    ])
                })
                .collect();
            Response::json(200, &json::obj(vec![("unmet", json::arr(flags))]))
        }
        _ => {
            // A published outlook by version - seller and ads views read this.
            if let ("GET", Some(version)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/outlooks/"))
            {
                return match state.outlooks.iter().find(|(v, _)| v == version) {
                    Some((_, o)) => Response::json(200, o),
                    None => Response::error(404, "no such outlook version"),
                };
            }
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "insights-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            cycles: Vec::new(),
            cells: Vec::new(),
            outlooks: Vec::new(),
        },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn below_threshold_cells_are_suppressed_not_zeroed() {
        let cells = vec![
            Cell { category: "housewares".into(), region: "region-a".into(), needs: 6, offers: 1 },
            Cell { category: "housewares".into(), region: "region-b".into(), needs: 2, offers: 0 },
        ];
        let pub_ = published_aggregates(&cells);
        // The above-threshold region appears; the below-threshold one is
        // absent entirely (not a zero figure).
        assert_eq!(pub_.len(), 1);
        let text = json::arr(pub_).dump();
        assert!(text.contains("region-a") && !text.contains("region-b"), "{text}");
    }

    #[test]
    fn aggregates_report_cycle_history_without_identity() {
        let mut state = State {
            cycles: vec![2, 0],
            cells: Vec::new(),
            outlooks: Vec::new(),
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
