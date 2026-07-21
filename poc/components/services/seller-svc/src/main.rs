// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC seller-svc: offer catalog with standing auto-close deals and the
// order state machine (committed -> provisioning -> fulfilled; a closed match
// creates the order already committed). Advancing to fulfilled confirms
// settlement on the ledger. Order records structurally contain no buyer
// identity - there is no such field. With DATABASE_URL set, offers and orders
// write through to PostgreSQL first and reload on start (catalog and order
// board survive pod restarts); without it the store is in-memory.

use amisad_common::{json, request, serve_app, Request, Response, ServiceInfo};
use postgres::{Client, NoTls};

struct Order {
    match_id: String,
    offer_id: String,
    tenant: String,
    need_context: String,
    state: String,
    // In-person booking (s002.fitting): the appointment slot, empty for
    // plain fulfillment orders. Structurally identity-free like the rest.
    slot_id: String,
    slot_day: String,
}

struct State {
    offers: Vec<json::Json>,
    orders: Vec<Order>,
    // s007.inventory: per-offer stock. Absent = not inventory-tracked
    // (available); 0 = out of stock and NOT matchable. In-memory: the
    // integration control plane is transient like connect-svc.
    stock: Vec<(String, i64)>,
    db: Option<Client>,
}

/// DATABASE_URL unset/empty -> in-memory. Set but unreachable -> exit(1);
/// kubernetes restarts the pod until PostgreSQL accepts connections.
fn open_db() -> Option<Client> {
    let url = match std::env::var("DATABASE_URL") {
        Ok(u) if !u.is_empty() => u,
        _ => return None,
    };
    match Client::connect(&url, NoTls) {
        Ok(c) => Some(c),
        Err(e) => {
            eprintln!("seller-svc: DATABASE_URL set but connection failed: {e}");
            std::process::exit(1);
        }
    }
}

/// A dead connection means every future write 503s while /health stays green
/// (probes never touch the store) - exit instead and let kubernetes restart
/// the pod, which rehydrates from the database. SQL-level errors (constraint
/// violations etc.) keep the connection alive and surface as 503.
fn store_error(db: &Client, what: &str, e: postgres::Error) -> Response {
    if db.is_closed() {
        eprintln!("seller-svc: {what}: connection lost ({e}); exiting to reload");
        std::process::exit(1);
    }
    Response::error(503, &format!("{what} unavailable: {e}"))
}

fn load_store(db: &mut Client) -> (Vec<json::Json>, Vec<Order>) {
    let offers = db
        .query("SELECT document FROM seller.offers ORDER BY created_at, offer_id", &[])
        .unwrap_or_else(|e| {
            eprintln!("seller-svc: loading offers failed: {e}");
            std::process::exit(1);
        })
        .iter()
        .filter_map(|row| {
            let doc: String = row.get(0);
            match json::parse(&doc) {
                Ok(o) if o.str_of("offer_id").is_some() => Some(o),
                // e.g. a direct-SQL seed that skipped the document column.
                _ => {
                    eprintln!("seller-svc: WARNING skipping offer with unusable document: {doc}");
                    None
                }
            }
        })
        .collect();
    let orders = db
        .query(
            "SELECT match_id, offer_id, tenant, need_context, state, slot_id, slot_day FROM seller.orders ORDER BY created_at, match_id",
            &[],
        )
        .unwrap_or_else(|e| {
            eprintln!("seller-svc: loading orders failed: {e}");
            std::process::exit(1);
        })
        .iter()
        .map(|row| Order {
            match_id: row.get(0),
            offer_id: row.get(1),
            tenant: row.get(2),
            need_context: row.get(3),
            state: row.get(4),
            slot_id: row.get(5),
            slot_day: row.get(6),
        })
        .collect();
    (offers, orders)
}

fn ledger_url() -> String {
    std::env::var("LEDGER_URL").unwrap_or_else(|_| String::from("http://ledger-svc:8080"))
}
fn coordinator_url() -> String {
    std::env::var("COORDINATOR_URL")
        .unwrap_or_else(|_| String::from("http://fabric-coordinator:8080"))
}
fn connect_url() -> String {
    std::env::var("CONNECT_URL").unwrap_or_else(|_| String::from("http://connect-svc:8080"))
}

/// Order-lifecycle event to the integration gateway (s007.inventory): every
/// order state transition is mirrored to the connector's ERP feed. Detached
/// and best-effort, like the offer-published event - the seller never blocks
/// on connect.
fn notify_order_event(match_id: String, tenant: String, state: String) {
    std::thread::spawn(move || {
        let body = json::obj(vec![
            ("match_id", json::s(&match_id)),
            ("tenant", json::s(&tenant)),
            ("state", json::s(&state)),
        ])
        .dump();
        match request("POST", &format!("{}/v1/orders/events", connect_url()), Some(&body)) {
            Ok((status, resp)) if status >= 300 => {
                eprintln!("order-event to connect returned {status}: {resp}");
            }
            Err(e) => eprintln!("order-event to connect failed: {e}"),
            Ok(_) => {}
        }
    });
}

/// Offer-published event to the fabric (s003: a new offer may fit an open
/// need). Detached thread on purpose: this single-threaded server must NOT
/// block on the coordinator, whose matching cycle calls back into our
/// catalog - a synchronous notify would deadlock the pair. (Direct HTTP
/// event; NATS JetStream remains the target transport - poc/README.md.)
fn notify_offer_published(offer: String) {
    std::thread::spawn(move || {
        match request(
            "POST",
            &format!("{}/v1/offers/published", coordinator_url()),
            Some(&offer),
        ) {
            Ok((status, body)) if status >= 300 => {
                eprintln!("offer-published event returned {status}: {body}");
            }
            Err(e) => eprintln!("offer-published event failed: {e}"),
            Ok(_) => {}
        }
    });
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
    let mut pairs = vec![
        ("match_id", json::s(&order.match_id)),
        ("offer_id", json::s(&order.offer_id)),
        ("tenant", json::s(&order.tenant)),
        ("need_context", json::s(&order.need_context)),
        ("state", json::s(&order.state)),
    ];
    if !order.slot_id.is_empty() {
        pairs.push((
            "appointment",
            json::obj(vec![
                ("slot_id", json::s(&order.slot_id)),
                ("day", json::s(&order.slot_day)),
            ]),
        ));
    }
    json::obj(pairs)
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
            if let Some(db) = state.db.as_mut() {
                if let Err(e) = db.execute(
                    "INSERT INTO seller.offers (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close, document) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) \
                     ON CONFLICT (offer_id) DO UPDATE SET tenant = $2, title = $3, category = $4, region = $5, price_cents = $6, deliver_by_days = $7, auto_close = $8, document = $9",
                    &[
                        &offer_id,
                        &body.str_of("tenant").unwrap_or(""),
                        &body.str_of("title").unwrap_or(""),
                        &body.str_of("category").unwrap_or(""),
                        &body.str_of("region").unwrap_or(""),
                        &body.i64_of("price_cents").unwrap_or(0),
                        &body.i64_of("deliver_by_days").and_then(|d| i32::try_from(d).ok()),
                        &body.bool_of("auto_close").unwrap_or(false),
                        &body.dump(),
                    ],
                ) {
                    return store_error(db, "catalog store", e);
                }
            }
            // Upsert in memory too, matching the database's primary key.
            let offer_text = body.dump();
            match state
                .offers
                .iter_mut()
                .find(|o| o.str_of("offer_id") == Some(&offer_id))
            {
                Some(existing) => *existing = body,
                None => state.offers.push(body),
            }
            notify_offer_published(offer_text);
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
            // Validated here so both storage modes agree; the database FK
            // would otherwise misreport this client error as a 503 outage.
            if !state
                .offers
                .iter()
                .any(|o| o.str_of("offer_id") == Some(offer_id.as_str()))
            {
                return Response::error(400, "unknown offer_id");
            }
            let order = Order {
                match_id: match_id.clone(),
                offer_id,
                tenant,
                need_context: body.str_of("need_context").unwrap_or("").to_string(),
                state: String::from("committed"),
                slot_id: body.str_of("slot_id").unwrap_or("").to_string(),
                slot_day: body.str_of("slot_day").unwrap_or("").to_string(),
            };
            if let Some(db) = state.db.as_mut() {
                if let Err(e) = db.execute(
                    "INSERT INTO seller.orders (match_id, offer_id, tenant, need_context, state, slot_id, slot_day) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7)",
                    &[
                        &order.match_id,
                        &order.offer_id,
                        &order.tenant,
                        &order.need_context,
                        &order.state,
                        &order.slot_id,
                        &order.slot_day,
                    ],
                ) {
                    return store_error(db, "order store", e);
                }
            }
            let tenant = order.tenant.clone();
            state.orders.push(order);
            notify_order_event(match_id.clone(), tenant, String::from("committed"));
            Response::json(
                201,
                &json::obj(vec![
                    ("match_id", json::s(&match_id)),
                    ("state", json::s("committed")),
                ]),
            )
        }
        ("GET", "/v1/orders") => {
            // The order board: everything on it, appointment included. Also
            // how the harness asserts "zero commitments before the buyer acts".
            let orders: Vec<json::Json> = state.orders.iter().map(order_json).collect();
            Response::json(
                200,
                &json::obj(vec![
                    ("count", json::n(state.orders.len() as i64)),
                    ("orders", json::arr(orders)),
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
            let index = match state.orders.iter().position(|o| o.match_id == match_id) {
                Some(i) => i,
                None => return Response::error(404, "no order for match_id"),
            };
            if !next_state(&state.orders[index].state, &requested) {
                return Response::error(
                    409,
                    &format!("illegal transition {} -> {requested}", state.orders[index].state),
                );
            }
            // Resolve the FINAL state first, then persist it as one write and
            // apply to memory last - so a store failure (503, memory
            // untouched) is always retryable, and a crash never leaves the
            // database mid-transition.
            let mut final_state = requested.clone();
            if requested == "fulfilled" {
                let confirm_body =
                    json::obj(vec![("match_id", json::s(&match_id))]).dump();
                match request(
                    "POST",
                    &format!("{}/v1/settlements/confirm", ledger_url()),
                    Some(&confirm_body),
                ) {
                    Ok((201, _)) => final_state = String::from("settled"),
                    // A previous attempt already confirmed (crash or 503
                    // between confirm and persist): converge to settled
                    // instead of wedging at fulfilled.
                    Ok((409, body)) if body.contains("already confirmed") => {
                        final_state = String::from("settled");
                    }
                    Ok((status, body)) => {
                        eprintln!("settlement confirm returned {status}: {body}");
                    }
                    Err(e) => eprintln!("settlement confirm failed: {e}"),
                }
            }
            if let Some(db) = state.db.as_mut() {
                if let Err(e) = db.execute(
                    "UPDATE seller.orders SET state = $1, updated_at = now() WHERE match_id = $2",
                    &[&final_state, &match_id],
                ) {
                    return store_error(db, "order store", e);
                }
            }
            state.orders[index].state = final_state.clone();
            let tenant = state.orders[index].tenant.clone();
            notify_order_event(match_id.clone(), tenant, final_state);
            Response::json(
                200,
                &json::obj(vec![
                    ("match_id", json::s(&match_id)),
                    ("state", json::s(&state.orders[index].state)),
                ]),
            )
        }
        // s007.inventory: an external inventory delta sets an offer's stock;
        // 0 removes it from the matchable catalog within the sync window.
        ("POST", "/v1/offers/inventory") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let offer_id = match body.str_of("offer_id") {
                Some(o) => o.to_string(),
                None => return Response::error(400, "offer_id required"),
            };
            let stock = match body.i64_of("stock") {
                Some(s) if s >= 0 => s,
                _ => return Response::error(400, "stock (>= 0) required"),
            };
            if !state.offers.iter().any(|o| o.str_of("offer_id") == Some(offer_id.as_str())) {
                return Response::error(404, "unknown offer_id");
            }
            state.stock.retain(|(id, _)| *id != offer_id);
            state.stock.push((offer_id.clone(), stock));
            Response::json(
                200,
                &json::obj(vec![("offer_id", json::s(&offer_id)), ("stock", json::n(stock))]),
            )
        }
        _ => {
            if let ("GET", Some(region)) =
                (req.method.as_str(), path.strip_prefix("/v1/offers/region/"))
            {
                // An offer whose stock was zeroed (s007) is NOT matchable -
                // external inventory truth governs matching. Untracked offers
                // (no stock entry) stay available.
                let offers: Vec<json::Json> = state
                    .offers
                    .iter()
                    .filter(|o| o.str_of("region") == Some(region))
                    .filter(|o| {
                        let id = o.str_of("offer_id").unwrap_or("");
                        !state.stock.iter().any(|(sid, s)| sid == id && *s == 0)
                    })
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
    let mut db = open_db();
    let (offers, orders) = match db.as_mut() {
        Some(client) => load_store(client),
        None => (Vec::new(), Vec::new()),
    };
    serve_app(
        ServiceInfo {
            name: "seller-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State { offers, orders, stock: Vec::new(), db },
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
            slot_id: String::new(),
            slot_day: String::new(),
        };
        let text = order_json(&order).dump();
        for marker in ["buyer", "identity", "subscriber", "maya", "token"] {
            assert!(!text.contains(marker), "order leaked marker: {marker}");
        }
        assert!(!text.contains("appointment"), "no appointment without a slot");
    }

    #[test]
    fn booked_order_carries_an_identity_free_appointment() {
        let order = Order {
            match_id: "m2".to_string(),
            offer_id: "linen-midi-04".to_string(),
            tenant: "elena-atelier".to_string(),
            need_context: "midi dress fitting before Friday".to_string(),
            state: "committed".to_string(),
            slot_id: "thu-1".to_string(),
            slot_day: "thursday".to_string(),
        };
        let record = order_json(&order);
        let appointment = record.get("appointment").expect("appointment present");
        assert_eq!(appointment.str_of("slot_id"), Some("thu-1"));
        assert_eq!(appointment.str_of("day"), Some("thursday"));
        let text = record.dump();
        for marker in ["buyer", "identity", "subscriber", "maya", "token"] {
            assert!(!text.contains(marker), "appointment leaked marker: {marker}");
        }
    }
}
