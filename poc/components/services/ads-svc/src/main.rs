// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC ads-svc: campaign administration and creative studio marketplace
// (s005.attribution). Marcel (agency) creates a campaign and issues a creative
// brief; Kai (creator) accepts it and produces an approved asset; Marcel
// activates the campaign with that asset. Active campaigns are fetched by the
// fabric for the region and, inside the sealed environment, boost a qualifying
// offer with the creative. A closed boosted match records attribution here
// (agency + creator credit, campaign + asset ids) and decrements the campaign
// budget by the per-match commitment - never by impressions. Every view is
// aggregate: no buyer signal ever reaches this service. In-memory (POC).

use amisad_common::{ad_split, json, request, serve_app, sha256, Request, Response, ServiceInfo};

fn insights_url() -> String {
    std::env::var("INSIGHTS_URL").unwrap_or_else(|_| String::from("http://insights-svc:8080"))
}

struct Campaign {
    id: String,
    tenant: String,
    region: String,
    category: String,
    ad_cents_per_match: i64,
    budget_cents: i64,
    spent_cents: i64,
    asset_id: String,
    state: String, // draft | active
}

struct Brief {
    id: String,
    campaign_id: String,
}

struct Asset {
    id: String,
    campaign_id: String,
    creator: String,
    creative: String,
    state: String, // approved
}

struct State {
    campaigns: Vec<Campaign>,
    briefs: Vec<Brief>,
    assets: Vec<Asset>,
    attributions: Vec<json::Json>,
}

fn short_id(prefix: &str, seed: &str) -> String {
    format!("{prefix}-{}", &sha256::hex_digest(seed.as_bytes())[..12])
}

fn campaign_json(c: &Campaign) -> json::Json {
    json::obj(vec![
        ("campaign_id", json::s(&c.id)),
        ("tenant", json::s(&c.tenant)),
        ("region", json::s(&c.region)),
        ("category", json::s(&c.category)),
        ("ad_cents_per_match", json::n(c.ad_cents_per_match)),
        ("budget_cents", json::n(c.budget_cents)),
        ("spent_cents", json::n(c.spent_cents)),
        ("asset_id", json::s(&c.asset_id)),
        ("state", json::s(&c.state)),
    ])
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/campaigns") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            for field in ["tenant", "region", "category"] {
                if body.str_of(field).is_none() {
                    return Response::error(400, &format!("{field} required"));
                }
            }
            let ad_cents = body.i64_of("ad_cents_per_match").unwrap_or(0);
            let budget = body.i64_of("budget_cents").unwrap_or(0);
            if ad_cents <= 0 || budget < ad_cents {
                return Response::error(400, "ad_cents_per_match > 0 and budget_cents >= it required");
            }
            let id = short_id("camp", &format!("{}|{}", body.dump(), state.campaigns.len()));
            state.campaigns.push(Campaign {
                id: id.clone(),
                tenant: body.str_of("tenant").unwrap().to_string(),
                region: body.str_of("region").unwrap().to_string(),
                category: body.str_of("category").unwrap().to_string(),
                ad_cents_per_match: ad_cents,
                budget_cents: budget,
                spent_cents: 0,
                asset_id: String::new(),
                state: String::from("draft"),
            });
            Response::json(
                201,
                &json::obj(vec![("campaign_id", json::s(&id)), ("state", json::s("draft"))]),
            )
        }
        ("POST", "/v1/briefs") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let campaign_id = body.str_of("campaign_id").unwrap_or("").to_string();
            if !state.campaigns.iter().any(|c| c.id == campaign_id) {
                return Response::error(404, "unknown campaign");
            }
            let id = short_id("brief", &format!("{campaign_id}|{}", state.briefs.len()));
            state.briefs.push(Brief {
                id: id.clone(),
                campaign_id,
            });
            Response::json(201, &json::obj(vec![("brief_id", json::s(&id))]))
        }
        // Kai's demand queue: open briefs awaiting an asset.
        ("GET", "/v1/briefs") => {
            let open: Vec<json::Json> = state
                .briefs
                .iter()
                .filter(|b| !state.assets.iter().any(|a| a.campaign_id == b.campaign_id))
                .map(|b| {
                    json::obj(vec![
                        ("brief_id", json::s(&b.id)),
                        ("campaign_id", json::s(&b.campaign_id)),
                    ])
                })
                .collect();
            Response::json(200, &json::obj(vec![("briefs", json::arr(open))]))
        }
        // Kai produces the asset; revision->approval is collapsed to an
        // approved submission for the POC.
        ("POST", "/v1/assets") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let campaign_id = body.str_of("campaign_id").unwrap_or("").to_string();
            let creator = match body.str_of("creator") {
                Some(c) => c.to_string(),
                None => return Response::error(400, "creator required"),
            };
            if !state.campaigns.iter().any(|c| c.id == campaign_id) {
                return Response::error(404, "unknown campaign");
            }
            let creative = body.str_of("creative").unwrap_or("summer-collection-hero").to_string();
            let id = short_id("asset", &format!("{campaign_id}|{creator}|{}", state.assets.len()));
            state.assets.push(Asset {
                id: id.clone(),
                campaign_id,
                creator,
                creative,
                state: String::from("approved"),
            });
            Response::json(
                201,
                &json::obj(vec![("asset_id", json::s(&id)), ("state", json::s("approved"))]),
            )
        }
        // Marcel places the approved asset: the campaign goes active and
        // pacing begins.
        ("POST", "/v1/campaigns/activate") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let campaign_id = body.str_of("campaign_id").unwrap_or("").to_string();
            let asset_id = body.str_of("asset_id").unwrap_or("").to_string();
            let approved = state
                .assets
                .iter()
                .any(|a| a.id == asset_id && a.campaign_id == campaign_id && a.state == "approved");
            if !approved {
                return Response::error(409, "no approved asset for this campaign");
            }
            match state.campaigns.iter_mut().find(|c| c.id == campaign_id) {
                Some(c) => {
                    c.asset_id = asset_id.clone();
                    c.state = String::from("active");
                }
                None => return Response::error(404, "unknown campaign"),
            }
            Response::json(
                200,
                &json::obj(vec![("campaign_id", json::s(&campaign_id)), ("state", json::s("active"))]),
            )
        }
        // Attribution for a closed boosted match: records the credit and
        // decrements the budget by the per-match commitment (not impressions).
        // No buyer signal is accepted - match_id is an opaque hash.
        ("POST", "/v1/attributions") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let campaign_id = body.str_of("campaign_id").unwrap_or("").to_string();
            let (index, ad_cents) = match state
                .campaigns
                .iter()
                .position(|c| c.id == campaign_id && c.state == "active")
            {
                Some(i) => (i, state.campaigns[i].ad_cents_per_match),
                None => return Response::error(404, "no active campaign"),
            };
            // Pacing is a hard cap here, not just at feed time: never book a
            // commitment the budget cannot fund.
            if state.campaigns[index].spent_cents + ad_cents > state.campaigns[index].budget_cents {
                return Response::error(409, "campaign budget exhausted");
            }
            let asset_id = body.str_of("asset_id").unwrap_or("").to_string();
            let match_id = body.str_of("match_id").unwrap_or("").to_string();
            let (agency_cents, creator_cents) = ad_split(ad_cents);
            state.campaigns[index].spent_cents += ad_cents;
            let record = json::obj(vec![
                ("campaign_id", json::s(&campaign_id)),
                ("asset_id", json::s(&asset_id)),
                ("match_id", json::s(&match_id)),
                ("ad_cents", json::n(ad_cents)),
                ("agency_cents", json::n(agency_cents)),
                ("creator_cents", json::n(creator_cents)),
            ]);
            state.attributions.push(record.clone());
            Response::json(201, &record)
        }
        // Marcel's attribution report + Kai's performance view: aggregate
        // figures only, no buyer data.
        ("GET", "/v1/attributions") => {
            let agency_total: i64 = state
                .attributions
                .iter()
                .filter_map(|a| a.i64_of("agency_cents"))
                .sum();
            let creator_total: i64 = state
                .attributions
                .iter()
                .filter_map(|a| a.i64_of("creator_cents"))
                .sum();
            Response::json(
                200,
                &json::obj(vec![
                    ("closed_matches", json::n(state.attributions.len() as i64)),
                    ("agency_cents_total", json::n(agency_total)),
                    ("creator_cents_total", json::n(creator_total)),
                    ("attributions", json::arr(state.attributions.clone())),
                ]),
            )
        }
        _ => {
            // Active campaigns for a region: the fabric fetches these and
            // boosts a matching offer inside the sealed environment.
            if let ("GET", Some(region)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/campaigns/region/"))
            {
                let list: Vec<json::Json> = state
                    .campaigns
                    .iter()
                    .filter(|c| c.state == "active" && c.region == region && c.spent_cents < c.budget_cents)
                    .map(|c| {
                        let creative = state
                            .assets
                            .iter()
                            .find(|a| a.id == c.asset_id)
                            .map(|a| (a.creative.clone(), a.creator.clone()))
                            .unwrap_or_default();
                        json::obj(vec![
                            ("campaign_id", json::s(&c.id)),
                            ("category", json::s(&c.category)),
                            ("tenant", json::s(&c.tenant)),
                            ("asset_id", json::s(&c.asset_id)),
                            ("ad_cents_per_match", json::n(c.ad_cents_per_match)),
                            ("creative", json::s(&creative.0)),
                            ("creator", json::s(&creative.1)),
                        ])
                    })
                    .collect();
                return Response::json(200, &json::obj(vec![("campaigns", json::arr(list))]));
            }
            if let ("GET", Some(id)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/campaigns/"))
            {
                return match state.campaigns.iter().find(|c| c.id == id) {
                    Some(c) => Response::json(200, &campaign_json(c)),
                    None => Response::error(404, "unknown campaign"),
                };
            }
            // s009.suppression: Marcel's aggregate demand view is a read of
            // the published insights outlook (identical to Elena's seller view
            // by construction).
            if let ("GET", Some(version)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/demand-view/"))
            {
                return match request(
                    "GET",
                    &format!("{}/v1/outlooks/{version}", insights_url()),
                    None,
                ) {
                    Ok((200, text)) => match json::parse(&text) {
                        Ok(o) => Response::json(200, &o),
                        Err(e) => Response::error(502, &format!("bad outlook: {e}")),
                    },
                    Ok((status, _)) => Response::error(status, "outlook unavailable"),
                    Err(e) => Response::error(503, &format!("insights unavailable: {e}")),
                };
            }
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "ads-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            campaigns: Vec::new(),
            briefs: Vec::new(),
            assets: Vec::new(),
            attributions: Vec::new(),
        },
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
    fn ad_split_is_sixty_forty_and_exact() {
        assert_eq!(ad_split(2000), (1200, 800));
        let (a, c) = ad_split(999);
        assert_eq!(a + c, 999);
    }

    #[test]
    fn campaign_lifecycle_and_attribution_flow() {
        let mut s = State {
            campaigns: Vec::new(),
            briefs: Vec::new(),
            assets: Vec::new(),
            attributions: Vec::new(),
        };
        let camp = handle(&mut s, &req("POST", "/v1/campaigns",
            "{\"tenant\":\"elena-atelier\",\"region\":\"region-a\",\"category\":\"housewares\",\"ad_cents_per_match\":2000,\"budget_cents\":10000}"));
        assert_eq!(camp.status, 201);
        let cid = json::parse(&camp.body).unwrap().str_of("campaign_id").unwrap().to_string();
        handle(&mut s, &req("POST", "/v1/briefs", &format!("{{\"campaign_id\":\"{cid}\"}}")));
        let asset = handle(&mut s, &req("POST", "/v1/assets",
            &format!("{{\"campaign_id\":\"{cid}\",\"creator\":\"kai\"}}")));
        let aid = json::parse(&asset.body).unwrap().str_of("asset_id").unwrap().to_string();
        // Not active until the approved asset is placed.
        assert_eq!(
            handle(&mut s, &req("GET", "/v1/campaigns/region/region-a", ""))
                .body.contains(&cid), false
        );
        let act = handle(&mut s, &req("POST", "/v1/campaigns/activate",
            &format!("{{\"campaign_id\":\"{cid}\",\"asset_id\":\"{aid}\"}}")));
        assert_eq!(act.status, 200);
        let active = handle(&mut s, &req("GET", "/v1/campaigns/region/region-a", ""));
        assert!(active.body.contains(&cid) && active.body.contains(&aid));
        let attr = handle(&mut s, &req("POST", "/v1/attributions",
            &format!("{{\"campaign_id\":\"{cid}\",\"asset_id\":\"{aid}\",\"match_id\":\"m1\"}}")));
        assert_eq!(attr.status, 201);
        let a = json::parse(&attr.body).unwrap();
        assert_eq!(a.i64_of("agency_cents"), Some(1200));
        assert_eq!(a.i64_of("creator_cents"), Some(800));
        // Budget decremented by the per-match commitment.
        let report = handle(&mut s, &req("GET", &format!("/v1/campaigns/{cid}"), ""));
        assert_eq!(json::parse(&report.body).unwrap().i64_of("spent_cents"), Some(2000));
    }
}
