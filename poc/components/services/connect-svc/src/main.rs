// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC connect-svc: supply-side integration gateway (s007.inventory).
// Alex registers as a partner (Priya's registry verifies -> sandbox only) and
// certifies a connector; Elena grants scoped access (catalog, inventory,
// orders) and the gateway issues a credential capped to exactly that scope.
// The connector syncs Elena's ERP catalog and inventory deltas into her
// tenant (driving matching against external truth), receives order-lifecycle
// events and mirrors each to the ERP idempotently, refuses and logs
// out-of-scope calls, and dies on revocation. No buyer identity or need
// content ever crosses this surface. In-memory (POC).

use amisad_common::{json, request, serve_app, sha256, Request, Response, ServiceInfo};

struct Partner {
    id: String,
    certified: bool,
}

struct Grant {
    credential: String,
    tenant: String,
    scopes: Vec<String>,
    revoked: bool,
}

struct State {
    partners: Vec<Partner>,
    grants: Vec<Grant>,
    deltas: Vec<json::Json>,          // inventory deltas (offer_id, stock, delta_ts)
    erp_orders: Vec<(String, String)>, // ERP mirror: (match_id, latest state)
    deliveries: Vec<(String, String)>, // applied (match_id, state) - idempotency key
    audit: Vec<json::Json>,            // refused/attempted out-of-scope calls
}

fn seller_url() -> String {
    std::env::var("SELLER_URL").unwrap_or_else(|_| String::from("http://seller-svc:8080"))
}

fn short(prefix: &str, seed: &str) -> String {
    format!("{prefix}-{}", &sha256::hex_digest(seed.as_bytes())[..16])
}

/// Resolve a credential to its grant. Err carries the response to return:
/// 401 for unknown/revoked, 403 (logged) for an out-of-scope call.
fn authorize<'a>(
    state: &'a mut State,
    credential: &str,
    scope: &str,
) -> Result<usize, Response> {
    let index = state.grants.iter().position(|g| g.credential == credential);
    let index = match index {
        Some(i) if !state.grants[i].revoked => i,
        _ => return Err(Response::error(401, "invalid or revoked credential")),
    };
    if !state.grants[index].scopes.iter().any(|s| s == scope) {
        state.audit.push(json::obj(vec![
            ("event", json::s("out-of-scope")),
            ("scope", json::s(scope)),
            ("tenant", json::s(&state.grants[index].tenant)),
        ]));
        return Err(Response::error(403, &format!("credential not scoped for '{scope}'")));
    }
    Ok(index)
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        // Alex registers; the participant registry verifies and grants
        // sandbox access only.
        ("POST", "/v1/partners") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let name = match body.str_of("name") {
                Some(n) => n.to_string(),
                None => return Response::error(400, "name required"),
            };
            let id = short("partner", &format!("{name}|{}", state.partners.len()));
            state.partners.push(Partner {
                id: id.clone(),
                certified: false,
            });
            Response::json(
                201,
                &json::obj(vec![("partner_id", json::s(&id)), ("access", json::s("sandbox"))]),
            )
        }
        // Sandbox certification (contract conformance collapsed to a pass).
        ("POST", "/v1/partners/certify") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let partner_id = body.str_of("partner_id").unwrap_or("").to_string();
            match state.partners.iter_mut().find(|p| p.id == partner_id) {
                Some(p) => p.certified = true,
                None => return Response::error(404, "unknown partner"),
            }
            Response::json(200, &json::obj(vec![("partner_id", json::s(&partner_id)), ("certified", json::b(true))]))
        }
        // Elena grants scoped access; the credential ceiling is exactly the
        // granted scopes.
        ("POST", "/v1/grants") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let tenant = body.str_of("tenant").unwrap_or("").to_string();
            let partner_id = body.str_of("partner_id").unwrap_or("").to_string();
            if !state.partners.iter().any(|p| p.id == partner_id && p.certified) {
                return Response::error(403, "partner not certified");
            }
            let scopes: Vec<String> = body
                .get("scopes")
                .and_then(|s| s.as_arr())
                .map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            if tenant.is_empty() || scopes.is_empty() {
                return Response::error(400, "tenant and scopes (non-empty) required");
            }
            let credential = short("cred", &format!("{tenant}|{partner_id}|{}", state.grants.len()));
            state.grants.push(Grant {
                credential: credential.clone(),
                tenant,
                scopes: scopes.clone(),
                revoked: false,
            });
            Response::json(
                201,
                &json::obj(vec![
                    ("credential", json::s(&credential)),
                    ("scopes", json::arr(scopes.iter().map(|s| json::s(s)).collect())),
                ]),
            )
        }
        ("POST", "/v1/grants/revoke") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let credential = body.str_of("credential").unwrap_or("");
            match state.grants.iter_mut().find(|g| g.credential == credential) {
                Some(g) => g.revoked = true,
                None => return Response::error(404, "unknown credential"),
            }
            Response::json(200, &json::obj(vec![("revoked", json::b(true))]))
        }
        // Catalog sync: push the ERP catalog into the seller tenant. Scope
        // 'catalog'.
        ("POST", "/v1/sync/catalog") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let credential = body.str_of("credential").unwrap_or("").to_string();
            if let Err(resp) = authorize(state, &credential, "catalog") {
                return resp;
            }
            let empty = Vec::new();
            let offers = body.get("offers").and_then(|o| o.as_arr()).unwrap_or(&empty).clone();
            let mut synced = 0;
            for offer in &offers {
                match request("POST", &format!("{}/v1/offers", seller_url()), Some(&offer.dump())) {
                    Ok((201, _)) => synced += 1,
                    Ok((status, resp)) => return Response::error(502, &format!("seller offer ({status}): {resp}")),
                    Err(e) => return Response::error(503, &format!("seller unavailable: {e}")),
                }
            }
            Response::json(200, &json::obj(vec![("synced", json::n(synced))]))
        }
        // Inventory delta: zero (or set) an offer's stock in the tenant, and
        // record the delta with its timestamp. Scope 'inventory'.
        ("POST", "/v1/sync/inventory") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let credential = body.str_of("credential").unwrap_or("").to_string();
            if let Err(resp) = authorize(state, &credential, "inventory") {
                return resp;
            }
            let offer_id = body.str_of("offer_id").unwrap_or("").to_string();
            let stock = body.i64_of("stock").unwrap_or(-1);
            let delta_ts = body.i64_of("delta_ts").unwrap_or(0);
            if offer_id.is_empty() || stock < 0 {
                return Response::error(400, "offer_id and stock (>= 0) required");
            }
            let update = json::obj(vec![
                ("offer_id", json::s(&offer_id)),
                ("stock", json::n(stock)),
            ])
            .dump();
            match request("POST", &format!("{}/v1/offers/inventory", seller_url()), Some(&update)) {
                Ok((200, _)) => {}
                Ok((status, resp)) => return Response::error(502, &format!("seller inventory ({status}): {resp}")),
                Err(e) => return Response::error(503, &format!("seller unavailable: {e}")),
            }
            state.deltas.push(json::obj(vec![
                ("offer_id", json::s(&offer_id)),
                ("stock", json::n(stock)),
                ("delta_ts", json::n(delta_ts)),
            ]));
            Response::json(200, &json::obj(vec![("offer_id", json::s(&offer_id)), ("stock", json::n(stock))]))
        }
        ("GET", "/v1/deltas") => Response::json(
            200,
            &json::obj(vec![("deltas", json::arr(state.deltas.clone()))]),
        ),
        // Order-lifecycle event from seller-svc: mirror to the ERP. Idempotent
        // by (match_id, state) - a replay produces no duplicate effect.
        ("POST", "/v1/orders/events") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let match_id = body.str_of("match_id").unwrap_or("").to_string();
            let order_state = body.str_of("state").unwrap_or("").to_string();
            if match_id.is_empty() || order_state.is_empty() {
                return Response::error(400, "match_id and state required");
            }
            let duplicate = state
                .deliveries
                .iter()
                .any(|(m, s)| *m == match_id && *s == order_state);
            if !duplicate {
                state.deliveries.push((match_id.clone(), order_state.clone()));
                state.erp_orders.retain(|(m, _)| *m != match_id);
                state.erp_orders.push((match_id.clone(), order_state.clone()));
            }
            Response::json(200, &json::obj(vec![("mirrored", json::b(true)), ("duplicate", json::b(duplicate))]))
        }
        // The harness replays a delivery: same (match_id, state) must NOT
        // create a duplicate order effect.
        ("POST", "/v1/webhooks/replay") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let match_id = body.str_of("match_id").unwrap_or("").to_string();
            let order_state = body.str_of("state").unwrap_or("").to_string();
            let duplicate = state
                .deliveries
                .iter()
                .any(|(m, s)| *m == match_id && *s == order_state);
            // A replay of a known delivery is a no-op; an unseen one applies.
            if !duplicate {
                state.deliveries.push((match_id.clone(), order_state.clone()));
                state.erp_orders.retain(|(m, _)| *m != match_id);
                state.erp_orders.push((match_id.clone(), order_state.clone()));
            }
            Response::json(200, &json::obj(vec![("duplicate", json::b(duplicate))]))
        }
        // A scoped query. Granted scope returns ok; anything else refuses and
        // logs, returning no data.
        ("POST", "/v1/query") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let credential = body.str_of("credential").unwrap_or("").to_string();
            let resource = body.str_of("resource").unwrap_or("").to_string();
            if let Err(resp) = authorize(state, &credential, &resource) {
                return resp;
            }
            Response::json(200, &json::obj(vec![("resource", json::s(&resource)), ("ok", json::b(true))]))
        }
        ("GET", "/v1/audit") => Response::json(
            200,
            &json::obj(vec![("audit", json::arr(state.audit.clone()))]),
        ),
        _ => {
            if let ("GET", Some(match_id)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/erp/orders/"))
            {
                return match state.erp_orders.iter().find(|(m, _)| m == match_id) {
                    Some((_, s)) => Response::json(200, &json::obj(vec![
                        ("match_id", json::s(match_id)),
                        ("state", json::s(s)),
                    ])),
                    None => Response::error(404, "no ERP order"),
                };
            }
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "connect-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            partners: Vec::new(),
            grants: Vec::new(),
            deltas: Vec::new(),
            erp_orders: Vec::new(),
            deliveries: Vec::new(),
            audit: Vec::new(),
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

    fn state() -> State {
        State {
            partners: Vec::new(),
            grants: Vec::new(),
            deltas: Vec::new(),
            erp_orders: Vec::new(),
            deliveries: Vec::new(),
            audit: Vec::new(),
        }
    }

    #[test]
    fn scope_ceiling_refuses_and_logs_out_of_scope() {
        let mut s = state();
        s.grants.push(Grant {
            credential: "cred-1".to_string(),
            tenant: "elena-atelier".to_string(),
            scopes: vec!["catalog".to_string(), "orders".to_string()],
            revoked: false,
        });
        assert!(authorize(&mut s, "cred-1", "catalog").is_ok());
        let refused = authorize(&mut s, "cred-1", "settlement");
        assert!(refused.is_err());
        assert_eq!(s.audit.len(), 1);
        // Revocation kills the credential.
        s.grants[0].revoked = true;
        assert_eq!(authorize(&mut s, "cred-1", "catalog").unwrap_err().status, 401);
    }

    #[test]
    fn order_events_mirror_and_replay_is_idempotent() {
        let mut s = state();
        let ev = |m: &str, st: &str| format!("{{\"match_id\":\"{m}\",\"tenant\":\"t\",\"state\":\"{st}\"}}");
        handle(&mut s, &req("POST", "/v1/orders/events", &ev("m1", "committed")));
        handle(&mut s, &req("POST", "/v1/orders/events", &ev("m1", "settled")));
        assert_eq!(s.deliveries.len(), 2);
        let mirror = handle(&mut s, &req("GET", "/v1/erp/orders/m1", ""));
        assert_eq!(json::parse(&mirror.body).unwrap().str_of("state"), Some("settled"));
        // Replaying the settled delivery is a no-op.
        let replay = handle(&mut s, &req("POST", "/v1/webhooks/replay", "{\"match_id\":\"m1\",\"state\":\"settled\"}"));
        assert_eq!(json::parse(&replay.body).unwrap().bool_of("duplicate"), Some(true));
        assert_eq!(s.deliveries.len(), 2);
    }
}
