// AmisAd POC seller-svc: offer catalog with standing auto-close deals and the
// order state machine (committed -> provisioning -> fulfilled; a closed match
// creates the order already committed). Advancing to fulfilled confirms
// settlement on the ledger. Order records structurally contain no buyer
// identity - there is no such field.

use amisad_common::{json, request, serve_app, Request, Response, ServiceInfo};

struct Order {
    match_id: String,
    offer_id: String,
    tenant: String,
    need_context: String,
    state: String,
}

struct State {
    offers: Vec<json::Json>,
    orders: Vec<Order>,
}

fn ledger_url() -> String {
    std::env::var("LEDGER_URL").unwrap_or_else(|_| String::from("http://ledger-svc:8080"))
}

/// The only legal explicit advances. Fulfilled -> settled happens internally
/// on settlement confirmation, never by request.
fn next_state(current: &str, requested: &str) -> bool {
    matches!(
        (current, requested),
        ("committed", "provisioning") | ("provisioning", "fulfilled")
    )
}

fn order_json(order: &Order) -> json::Json {
    json::obj(vec![
        ("match_id", json::s(&order.match_id)),
        ("offer_id", json::s(&order.offer_id)),
        ("tenant", json::s(&order.tenant)),
        ("need_context", json::s(&order.need_context)),
        ("state", json::s(&order.state)),
    ])
}

fn handle(state: &mut State, req: &Request) -> Response {
    let path = req.path.as_str();
    match (req.method.as_str(), path) {
        ("POST", "/v1/offers") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            for field in ["offer_id", "tenant", "title", "category", "region"] {
                if body.str_of(field).is_none() {
                    return Response::error(400, &format!("{field} required"));
                }
            }
            if body.i64_of("price_cents").is_none() {
                return Response::error(400, "price_cents required");
            }
            let offer_id = body.str_of("offer_id").unwrap().to_string();
            state.offers.push(body);
            Response::json(201, &json::obj(vec![("offer_id", json::s(&offer_id))]))
        }
        ("POST", "/v1/orders") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let (match_id, offer_id, tenant) = match (
                body.str_of("match_id"),
                body.str_of("offer_id"),
                body.str_of("tenant"),
            ) {
                (Some(m), Some(o), Some(t)) => (m.to_string(), o.to_string(), t.to_string()),
                _ => return Response::error(400, "match_id, offer_id, tenant required"),
            };
            if state.orders.iter().any(|o| o.match_id == match_id) {
                return Response::error(409, "order exists for match_id");
            }
            let order = Order {
                match_id: match_id.clone(),
                offer_id,
                tenant,
                need_context: body.str_of("need_context").unwrap_or("").to_string(),
                state: String::from("committed"),
            };
            state.orders.push(order);
            Response::json(
                201,
                &json::obj(vec![
                    ("match_id", json::s(&match_id)),
                    ("state", json::s("committed")),
                ]),
            )
        }
        ("POST", "/v1/orders/advance") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let match_id = body.str_of("match_id").unwrap_or("").to_string();
            let requested = body.str_of("state").unwrap_or("").to_string();
            let order = match state.orders.iter_mut().find(|o| o.match_id == match_id) {
                Some(o) => o,
                None => return Response::error(404, "no order for match_id"),
            };
            if !next_state(&order.state, &requested) {
                return Response::error(
                    409,
                    &format!("illegal transition {} -> {requested}", order.state),
                );
            }
            order.state = requested.clone();
            if requested == "fulfilled" {
                let confirm_body =
                    json::obj(vec![("match_id", json::s(&match_id))]).dump();
                match request(
                    "POST",
                    &format!("{}/v1/settlements/confirm", ledger_url()),
                    Some(&confirm_body),
                ) {
                    Ok((201, _)) => order.state = String::from("settled"),
                    Ok((status, body)) => {
                        eprintln!("settlement confirm returned {status}: {body}");
                    }
                    Err(e) => eprintln!("settlement confirm failed: {e}"),
                }
            }
            Response::json(
                200,
                &json::obj(vec![
                    ("match_id", json::s(&match_id)),
                    ("state", json::s(&order.state)),
                ]),
            )
        }
        _ => {
            if let ("GET", Some(region)) =
                (req.method.as_str(), path.strip_prefix("/v1/offers/region/"))
            {
                let offers: Vec<json::Json> = state
                    .offers
                    .iter()
                    .filter(|o| o.str_of("region") == Some(region))
                    .cloned()
                    .collect();
                return Response::json(200, &json::obj(vec![("offers", json::arr(offers))]));
            }
            if let ("GET", Some(match_id)) =
                (req.method.as_str(), path.strip_prefix("/v1/orders/match/"))
            {
                return match state.orders.iter().find(|o| o.match_id == match_id) {
                    Some(order) => Response::json(200, &order_json(order)),
                    None => Response::error(404, "no order for match_id"),
                };
            }
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "seller-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            offers: Vec::new(),
            orders: Vec::new(),
        },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transitions_are_gated() {
        assert!(next_state("committed", "provisioning"));
        assert!(next_state("provisioning", "fulfilled"));
        assert!(!next_state("committed", "fulfilled"));
        assert!(!next_state("committed", "settled"));
        assert!(!next_state("fulfilled", "settled"));
        assert!(!next_state("settled", "provisioning"));
    }

    #[test]
    fn order_record_has_no_identity_field() {
        let order = Order {
            match_id: "m1".to_string(),
            offer_id: "o1".to_string(),
            tenant: "elena-atelier".to_string(),
            need_context: "wish-list serving set, deliver by day 14".to_string(),
            state: "committed".to_string(),
        };
        let text = order_json(&order).dump();
        for marker in ["buyer", "identity", "subscriber", "maya", "token"] {
            assert!(!text.contains(marker), "order leaked marker: {marker}");
        }
    }
}
