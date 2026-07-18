// AmisAd POC fabric-coordinator: routes need envelopes to sealed slice
// environments and relays results. By construction this service NEVER parses
// the envelope - it is carried as an opaque string from the buyer to the
// environment; only the slice-runtime opens it.

use amisad_common::{json, request, serve_app, sha256, Request, Response, ServiceInfo};

struct State {
    orders: Vec<(String, String)>, // (handle, match_id)
}

fn identity_url() -> String {
    std::env::var("IDENTITY_URL").unwrap_or_else(|_| String::from("http://identity-mock:8080"))
}
fn resource_url() -> String {
    std::env::var("RESOURCE_URL").unwrap_or_else(|_| String::from("http://resource-svc:8080"))
}
fn seller_url() -> String {
    std::env::var("SELLER_URL").unwrap_or_else(|_| String::from("http://seller-svc:8080"))
}

fn handle_for(match_id: &str) -> String {
    sha256::hex_digest(format!("{match_id}|handle").as_bytes())[..16].to_string()
}

/// Pseudonymous buyer-facing view of the seller-side order state.
fn buyer_status(seller_state: &str) -> &'static str {
    match seller_state {
        "committed" | "provisioning" => "in-progress",
        "fulfilled" | "settled" => "delivered",
        other => {
            let _ = other;
            "unknown"
        }
    }
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/needs") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let token = body.str_of("token").unwrap_or("");
            let jurisdiction = body.str_of("jurisdiction").unwrap_or("").to_string();
            // Opaque: read as a string, never parsed here.
            let envelope = match body.str_of("envelope") {
                Some(e) => e.to_string(),
                None => return Response::error(400, "envelope required"),
            };

            // 1. Verified subscriber only.
            let verify_body = json::obj(vec![("token", json::s(token))]).dump();
            match request(
                "POST",
                &format!("{}/v1/verify", identity_url()),
                Some(&verify_body),
            ) {
                Ok((200, _)) => {}
                Ok(_) => return Response::error(401, "unverified actor"),
                Err(e) => return Response::error(503, &format!("identity unavailable: {e}")),
            }

            // 2. Jurisdiction-compliant placement.
            let placement_body =
                json::obj(vec![("jurisdiction", json::s(&jurisdiction))]).dump();
            let placement = match request(
                "POST",
                &format!("{}/v1/placements", resource_url()),
                Some(&placement_body),
            ) {
                Ok((200, text)) => match json::parse(&text) {
                    Ok(p) => p,
                    Err(e) => return Response::error(502, &format!("bad placement: {e}")),
                },
                Ok((status, _)) => {
                    return Response::error(503, &format!("no placement ({status})"))
                }
                Err(e) => return Response::error(503, &format!("resource unavailable: {e}")),
            };
            let endpoint = placement.str_of("endpoint").unwrap_or("").to_string();

            // 3. Offers are public; fetch the jurisdiction's catalog.
            let offers = match request(
                "GET",
                &format!("{}/v1/offers/region/{jurisdiction}", seller_url()),
                None,
            ) {
                Ok((200, text)) => match json::parse(&text) {
                    Ok(o) => o.get("offers").cloned().unwrap_or(json::arr(Vec::new())),
                    Err(e) => return Response::error(502, &format!("bad offers: {e}")),
                },
                Ok((status, _)) => return Response::error(502, &format!("offers ({status})")),
                Err(e) => return Response::error(503, &format!("seller unavailable: {e}")),
            };

            // 4. The envelope and offers travel INTO the environment.
            let dispatch = json::obj(vec![
                ("jurisdiction", json::s(&jurisdiction)),
                ("envelope", json::s(&envelope)),
                ("offers", offers),
            ])
            .dump();
            let match_record = match request(
                "POST",
                &format!("{endpoint}/v1/environments"),
                Some(&dispatch),
            ) {
                Ok((201, text)) => match json::parse(&text) {
                    Ok(m) => m,
                    Err(e) => return Response::error(502, &format!("bad match record: {e}")),
                },
                Ok((404, _)) => return Response::error(404, "no fitting offer"),
                Ok((status, body)) => {
                    return Response::error(502, &format!("environment ({status}): {body}"))
                }
                Err(e) => return Response::error(503, &format!("slice unavailable: {e}")),
            };

            // 5. Committed order to the seller: need context only, no identity.
            let match_id = match_record.str_of("match_id").unwrap_or("").to_string();
            let offer = match_record.get("offer").cloned().unwrap_or(json::Json::Null);
            let order_body = json::obj(vec![
                ("match_id", json::s(&match_id)),
                ("offer_id", json::s(offer.str_of("offer_id").unwrap_or(""))),
                ("tenant", json::s(offer.str_of("tenant").unwrap_or(""))),
                (
                    "need_context",
                    json::s(match_record.str_of("need_context").unwrap_or("")),
                ),
            ])
            .dump();
            if let Err(e) = request(
                "POST",
                &format!("{}/v1/orders", seller_url()),
                Some(&order_body),
            ) {
                return Response::error(502, &format!("order create failed: {e}"));
            }

            let handle = handle_for(&match_id);
            state.orders.push((handle.clone(), match_id.clone()));
            Response::json(
                201,
                &json::obj(vec![
                    ("handle", json::s(&handle)),
                    ("match_id", json::s(&match_id)),
                    (
                        "environment_id",
                        json::s(match_record.str_of("environment_id").unwrap_or("")),
                    ),
                    ("offer", offer),
                ]),
            )
        }
        _ => {
            if let ("GET", Some(handle)) =
                (req.method.as_str(), req.path.strip_prefix("/v1/orders/"))
            {
                let match_id = match state.orders.iter().find(|(h, _)| h == handle) {
                    Some((_, m)) => m.clone(),
                    None => return Response::error(404, "unknown handle"),
                };
                return match request(
                    "GET",
                    &format!("{}/v1/orders/match/{match_id}", seller_url()),
                    None,
                ) {
                    Ok((200, text)) => match json::parse(&text) {
                        Ok(order) => {
                            let seller_state = order.str_of("state").unwrap_or("unknown");
                            Response::json(
                                200,
                                &json::obj(vec![
                                    ("handle", json::s(handle)),
                                    ("status", json::s(buyer_status(seller_state))),
                                ]),
                            )
                        }
                        Err(e) => Response::error(502, &format!("bad order: {e}")),
                    },
                    Ok((status, _)) => Response::error(502, &format!("order lookup ({status})")),
                    Err(e) => Response::error(503, &format!("seller unavailable: {e}")),
                };
            }
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "fabric-coordinator",
            version: env!("CARGO_PKG_VERSION"),
        },
        State { orders: Vec::new() },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handle_is_deterministic_and_short() {
        let a = handle_for("match-1");
        let b = handle_for("match-1");
        let c = handle_for("match-2");
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 16);
    }

    #[test]
    fn buyer_status_mapping() {
        assert_eq!(buyer_status("committed"), "in-progress");
        assert_eq!(buyer_status("provisioning"), "in-progress");
        assert_eq!(buyer_status("fulfilled"), "delivered");
        assert_eq!(buyer_status("settled"), "delivered");
        assert_eq!(buyer_status("weird"), "unknown");
    }
}
