// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC buyer-client: the headless buyer playing Maya. s001.fulfillment:
// submit (auto-close match as one JSON line) | wait <handle> | run.
// s002.fitting: shortlist (manual dress need -> handle + shortlist) |
// book <handle> <offer_id> <slot_id> | notifications <handle>.
// s003.silence: open <dress|decanter> (needs that stay open until a fitting
// offer appears) | pause | withdraw | resume | consents. The need JSON
// deliberately contains no identity fields - the token authenticates, the
// need describes.

use amisad_common::{json, request};
use std::process::exit;
use std::thread::sleep;
use std::time::Duration;

fn coordinator_url() -> String {
    std::env::var("COORDINATOR_URL")
        .unwrap_or_else(|_| String::from("http://fabric-coordinator:8080"))
}
fn identity_url() -> String {
    std::env::var("IDENTITY_URL").unwrap_or_else(|_| String::from("http://identity-mock:8080"))
}

/// Maya's s001.fulfillment need: wish-list gift, budget cap, delivery deadline,
/// automatic closing. `context` is the only part a seller ever sees.
fn need_json() -> json::Json {
    json::obj(vec![
        ("category", json::s("housewares")),
        ("budget_cents", json::n(12000)),
        ("region", json::s("region-a")),
        ("deadline_days", json::n(14)),
        ("auto_close", json::b(true)),
        (
            "context",
            json::s("Wedding gift from the couple's wish list, deliver to their city"),
        ),
    ])
}

/// Maya's s002.fitting need: a considered purchase with layered constraints,
/// an explicit exclusion, a fitting deadline (day ordinal, Monday=1), and
/// MANUAL closing - nothing may commit until she books.
fn dress_need_json() -> json::Json {
    json::obj(vec![
        ("category", json::s("dresses")),
        ("budget_cents", json::n(20000)),
        ("region", json::s("region-a")),
        ("deadline_days", json::n(4)),
        ("auto_close", json::b(false)),
        (
            "attributes",
            json::arr(vec![
                json::s("midi"),
                json::s("sleeves"),
                json::s("warm-fabric"),
            ]),
        ),
        ("exclusions", json::arr(vec![json::s("dusty-blue")])),
        ("fitting_before_ordinal", json::n(5)),
        (
            "context",
            json::s("Midi dress with sleeves in a warm-weather fabric; fitting near the office before Friday"),
        ),
    ])
}

/// s003.silence open need 1: an auto-close dress need no seeded offer fits
/// yet - it stays open until a seller publishes a fitting offer.
fn open_dress_need_json() -> json::Json {
    json::obj(vec![
        ("category", json::s("dresses")),
        ("budget_cents", json::n(20000)),
        ("region", json::s("region-a")),
        ("deadline_days", json::n(3)),
        ("auto_close", json::b(true)),
        (
            "attributes",
            json::arr(vec![
                json::s("midi"),
                json::s("sleeves"),
                json::s("warm-fabric"),
            ]),
        ),
        (
            "context",
            json::s("Midi dress with sleeves in a warm-weather fabric, ready this week"),
        ),
    ])
}

/// s003.silence open need 2: stays open for the whole scenario (nothing
/// published ever fits it), so aggregation still has one contributing need
/// until withdrawal ends contribution.
fn open_decanter_need_json() -> json::Json {
    json::obj(vec![
        ("category", json::s("housewares")),
        ("budget_cents", json::n(9000)),
        ("region", json::s("region-a")),
        ("deadline_days", json::n(21)),
        ("auto_close", json::b(true)),
        (
            "context",
            json::s("Crystal decanter for an anniversary, modest budget"),
        ),
    ])
}

/// s005.attribution need: a manual summer-collection need in the campaign's
/// category and region, so the sealed environment can boost Elena's offer
/// with Kai's creative. No fitting slot - Maya simply accepts.
fn summer_need_json() -> json::Json {
    json::obj(vec![
        ("category", json::s("housewares")),
        ("budget_cents", json::n(20000)),
        ("region", json::s("region-a")),
        ("deadline_days", json::n(14)),
        ("auto_close", json::b(false)),
        (
            "context",
            json::s("Summer entertaining set for the season"),
        ),
    ])
}

fn fail(message: &str) -> ! {
    eprintln!("buyer-client: {message}");
    exit(1)
}

fn issue_token() -> String {
    issue_token_for("maya")
}

/// Mint a token for a named actor (Maya by default; Pat for delegate mode).
fn issue_token_for(actor: &str) -> String {
    let token_body = json::obj(vec![
        ("actor", json::s(actor)),
        ("class", json::s("person")),
    ])
    .dump();
    match request(
        "POST",
        &format!("{}/v1/tokens", identity_url()),
        Some(&token_body),
    ) {
        Ok((201, text)) => match json::parse(&text)
            .ok()
            .and_then(|j| j.str_of("token").map(|t| t.to_string()))
        {
            Some(t) => t,
            None => fail("token response unreadable"),
        },
        Ok((status, body)) => fail(&format!("token request failed ({status}): {body}")),
        Err(e) => fail(&format!("identity unreachable: {e}")),
    }
}

fn consent(grant_type: &str, action: &str) {
    let body = json::obj(vec![
        ("token", json::s(&issue_token())),
        ("grant_type", json::s(grant_type)),
        ("action", json::s(action)),
    ])
    .dump();
    match request(
        "POST",
        &format!("{}/v1/consents", coordinator_url()),
        Some(&body),
    ) {
        Ok((201, text)) => println!("{}", text.trim()),
        Ok((status, body)) => fail(&format!("consent {action} failed ({status}): {body}")),
        Err(e) => fail(&format!("coordinator unreachable: {e}")),
    }
}

fn consents() {
    let body = json::obj(vec![("token", json::s(&issue_token()))]).dump();
    match request(
        "POST",
        &format!("{}/v1/consents/state", coordinator_url()),
        Some(&body),
    ) {
        Ok((200, text)) => println!("{}", text.trim()),
        Ok((status, body)) => fail(&format!("consent state failed ({status}): {body}")),
        Err(e) => fail(&format!("coordinator unreachable: {e}")),
    }
}

// --- s006.mandate: delegate mode ---------------------------------------

fn post_as(path: &str, body: &json::Json, ok: u16) {
    match request("POST", &format!("{}{path}", coordinator_url()), Some(&body.dump())) {
        Ok((s, text)) if s == ok => println!("{}", text.trim()),
        Ok((status, text)) => fail(&format!("{path} failed ({status}): {text}")),
        Err(e) => fail(&format!("coordinator unreachable: {e}")),
    }
}

fn grant_mandate(delegate: &str, category: &str, per_item_cents: i64) {
    post_as(
        "/v1/mandates",
        &json::obj(vec![
            ("token", json::s(&issue_token())), // Maya, the principal
            ("delegate", json::s(delegate)),
            ("category", json::s(category)),
            ("per_item_cents", json::n(per_item_cents)),
        ]),
        201,
    );
}

fn revoke_mandate(delegate: &str) {
    post_as(
        "/v1/mandates/revoke",
        &json::obj(vec![("token", json::s(&issue_token())), ("delegate", json::s(delegate))]),
        201,
    );
}

fn workspace(actor: &str) {
    post_as(
        "/v1/delegate/workspace",
        &json::obj(vec![("token", json::s(&issue_token_for(actor)))]),
        200,
    );
}

/// Pat states a delegated need. attribute (optional) narrows the need to a
/// premium offer, so the over-cap path can be exercised deterministically.
fn delegate_need(actor: &str, principal: &str, category: &str, budget_cents: i64, attribute: Option<&str>) {
    let mut need_pairs = vec![
        ("category", json::s(category)),
        ("budget_cents", json::n(budget_cents)),
        ("region", json::s("region-a")),
        ("deadline_days", json::n(30)),
        ("auto_close", json::b(false)),
        ("context", json::s("Delegated household purchase")),
    ];
    if let Some(a) = attribute {
        need_pairs.push(("attributes", json::arr(vec![json::s(a)])));
    }
    let envelope = json::obj(need_pairs).dump();
    post_as(
        "/v1/delegate/needs",
        &json::obj(vec![
            ("token", json::s(&issue_token_for(actor))),
            ("principal", json::s(principal)),
            ("category", json::s(category)),
            ("jurisdiction", json::s("region-a")),
            ("envelope", json::s(&envelope)),
        ]),
        201,
    );
}

fn approve(handle: &str) {
    post_as(
        "/v1/mandates/approve",
        &json::obj(vec![("token", json::s(&issue_token())), ("handle", json::s(handle))]),
        201,
    );
}

fn activity() {
    post_as("/v1/activity", &json::obj(vec![("token", json::s(&issue_token()))]), 200);
}

fn submit() -> json::Json {
    submit_need(&need_json())
}

fn submit_need(need: &json::Json) -> json::Json {
    let token = issue_token();

    // The need travels as an opaque envelope; only the sealed environment
    // opens it. (Envelope encryption is a noted POC deviation.)
    let need_body = json::obj(vec![
        ("token", json::s(&token)),
        ("jurisdiction", json::s("region-a")),
        ("envelope", json::s(&need.dump())),
    ])
    .dump();
    match request(
        "POST",
        &format!("{}/v1/needs", coordinator_url()),
        Some(&need_body),
    ) {
        Ok((201, text)) => match json::parse(&text) {
            Ok(result) => {
                println!("{}", result.dump());
                result
            }
            Err(e) => fail(&format!("match result unreadable: {e}")),
        },
        Ok((status, body)) => fail(&format!("need submission failed ({status}): {body}")),
        Err(e) => fail(&format!("coordinator unreachable: {e}")),
    }
}

fn book(handle: &str, offer_id: &str, slot_id: Option<&str>) {
    let mut pairs = vec![
        ("handle", json::s(handle)),
        ("offer_id", json::s(offer_id)),
    ];
    // A fitting booking (s002) names a slot; a plain accept (s005) omits it.
    if let Some(s) = slot_id {
        pairs.push(("slot_id", json::s(s)));
    }
    let body = json::obj(pairs).dump();
    match request(
        "POST",
        &format!("{}/v1/bookings", coordinator_url()),
        Some(&body),
    ) {
        Ok((201, text)) => println!("{}", text.trim()),
        Ok((status, body)) => fail(&format!("booking failed ({status}): {body}")),
        Err(e) => fail(&format!("coordinator unreachable: {e}")),
    }
}

fn notifications(handle: &str) {
    match request(
        "GET",
        &format!("{}/v1/notifications/{handle}", coordinator_url()),
        None,
    ) {
        Ok((200, text)) => println!("{}", text.trim()),
        Ok((status, body)) => fail(&format!("notifications failed ({status}): {body}")),
        Err(e) => fail(&format!("coordinator unreachable: {e}")),
    }
}

fn wait(handle: &str) {
    for _ in 0..90 {
        match request(
            "GET",
            &format!("{}/v1/orders/{handle}", coordinator_url()),
            None,
        ) {
            Ok((200, text)) => {
                if let Ok(order) = json::parse(&text) {
                    let status = order.str_of("status").unwrap_or("unknown");
                    println!("status: {status}");
                    if status == "delivered" {
                        return;
                    }
                }
            }
            Ok((status, body)) => eprintln!("status poll ({status}): {body}"),
            Err(e) => eprintln!("status poll failed: {e}"),
        }
        sleep(Duration::from_secs(2));
    }
    fail("timed out waiting for delivery");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("submit") => {
            submit();
        }
        Some("wait") => match args.get(2) {
            Some(handle) => wait(handle),
            None => fail("usage: buyer-client wait <handle>"),
        },
        Some("run") => {
            let result = submit();
            match result.str_of("handle") {
                Some(handle) => wait(&handle.to_string()),
                None => fail("no handle in match result"),
            }
        }
        Some("shortlist") => {
            submit_need(&dress_need_json());
        }
        Some("book") => match (args.get(2), args.get(3)) {
            (Some(handle), Some(offer_id)) => book(handle, offer_id, args.get(4).map(|s| s.as_str())),
            _ => fail("usage: buyer-client book <handle> <offer_id> [slot_id]"),
        },
        Some("campaign") => {
            submit_need(&summer_need_json());
        }
        Some("notifications") => match args.get(2) {
            Some(handle) => notifications(handle),
            None => fail("usage: buyer-client notifications <handle>"),
        },
        Some("open") => match args.get(2).map(|s| s.as_str()) {
            Some("dress") => {
                submit_need(&open_dress_need_json());
            }
            Some("decanter") => {
                submit_need(&open_decanter_need_json());
            }
            _ => fail("usage: buyer-client open <dress|decanter>"),
        },
        // s003.silence consent controls. Pause stops matching; withdraw also
        // ends aggregate contribution; resume re-grants both (and the
        // coordinator immediately re-serves the open needs).
        Some("pause") => consent("participation", "revoke"),
        Some("withdraw") => consent("contribution", "revoke"),
        Some("resume") => {
            consent("contribution", "grant");
            consent("participation", "grant");
        }
        Some("consents") => consents(),
        Some("grant-mandate") => match (args.get(2), args.get(3), args.get(4)) {
            (Some(delegate), Some(category), Some(cap)) => {
                grant_mandate(delegate, category, cap.parse().unwrap_or(0))
            }
            _ => fail("usage: buyer-client grant-mandate <delegate> <category> <per_item_cents>"),
        },
        Some("revoke-mandate") => match args.get(2) {
            Some(delegate) => revoke_mandate(delegate),
            None => fail("usage: buyer-client revoke-mandate <delegate>"),
        },
        Some("workspace") => match args.get(2) {
            Some(actor) => workspace(actor),
            None => fail("usage: buyer-client workspace <actor>"),
        },
        Some("delegate-need") => match (args.get(2), args.get(3), args.get(4)) {
            (Some(actor), Some(category), Some(budget)) => delegate_need(
                actor,
                "maya",
                category,
                budget.parse().unwrap_or(0),
                args.get(5).map(|s| s.as_str()),
            ),
            _ => fail("usage: buyer-client delegate-need <actor> <category> <budget_cents> [attribute]"),
        },
        Some("approve") => match args.get(2) {
            Some(handle) => approve(handle),
            None => fail("usage: buyer-client approve <handle>"),
        },
        Some("activity") => activity(),
        _ => fail(
            "usage: buyer-client submit | wait <handle> | run | shortlist | book <handle> <offer_id> <slot_id> | notifications <handle> | open <dress|decanter> | pause | withdraw | resume | consents",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn need_carries_no_identity() {
        let text = need_json().dump();
        for marker in ["maya", "name", "identity", "subscriber", "token", "phone"] {
            assert!(!text.contains(marker), "need leaked marker: {marker}");
        }
        let need = need_json();
        assert_eq!(need.i64_of("budget_cents"), Some(12000));
        assert_eq!(need.bool_of("auto_close"), Some(true));
        assert!(need.str_of("context").is_some());
    }

    #[test]
    fn open_needs_are_auto_close_and_identity_free() {
        for need in [open_dress_need_json(), open_decanter_need_json()] {
            assert_eq!(need.bool_of("auto_close"), Some(true));
            let text = need.dump();
            for marker in ["maya", "identity", "subscriber", "token", "phone"] {
                assert!(!text.contains(marker), "open need leaked marker: {marker}");
            }
        }
        // The decanter budget must stay below every seeded housewares offer,
        // or the need would match at submit time instead of staying open.
        let budget = open_decanter_need_json().i64_of("budget_cents").unwrap();
        assert!(budget < 11000, "decanter budget {budget} can match a seeded offer");
    }

    #[test]
    fn dress_need_is_manual_with_exclusions() {
        let need = dress_need_json();
        assert_eq!(need.bool_of("auto_close"), Some(false));
        assert_eq!(need.i64_of("fitting_before_ordinal"), Some(5));
        let exclusions = need.get("exclusions").and_then(|e| e.as_arr()).unwrap();
        assert!(exclusions.iter().any(|e| e.as_str() == Some("dusty-blue")));
        let text = need.dump();
        for marker in ["maya", "identity", "subscriber", "token", "phone"] {
            assert!(!text.contains(marker), "dress need leaked marker: {marker}");
        }
    }
}
