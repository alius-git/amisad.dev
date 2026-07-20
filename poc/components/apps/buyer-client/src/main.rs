// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC buyer-client: the headless buyer playing Maya. s001.fulfillment:
// submit (auto-close match as one JSON line) | wait <handle> | run.
// s002.fitting: shortlist (manual dress need -> handle + shortlist) |
// book <handle> <offer_id> <slot_id> | notifications <handle>. The need JSON
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

fn fail(message: &str) -> ! {
    eprintln!("buyer-client: {message}");
    exit(1)
}

fn submit() -> json::Json {
    submit_need(&need_json())
}

fn submit_need(need: &json::Json) -> json::Json {
    let token_body = json::obj(vec![
        ("actor", json::s("maya")),
        ("class", json::s("person")),
    ])
    .dump();
    let token = match request(
        "POST",
        &format!("{}/v1/tokens", identity_url()),
        Some(&token_body),
    ) {
        Ok((201, text)) => match json::parse(&text).ok().and_then(|j| {
            j.str_of("token").map(|t| t.to_string())
        }) {
            Some(t) => t,
            None => fail("token response unreadable"),
        },
        Ok((status, body)) => fail(&format!("token request failed ({status}): {body}")),
        Err(e) => fail(&format!("identity unreachable: {e}")),
    };

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

fn book(handle: &str, offer_id: &str, slot_id: &str) {
    let body = json::obj(vec![
        ("handle", json::s(handle)),
        ("offer_id", json::s(offer_id)),
        ("slot_id", json::s(slot_id)),
    ])
    .dump();
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
        Some("book") => match (args.get(2), args.get(3), args.get(4)) {
            (Some(handle), Some(offer_id), Some(slot_id)) => book(handle, offer_id, slot_id),
            _ => fail("usage: buyer-client book <handle> <offer_id> <slot_id>"),
        },
        Some("notifications") => match args.get(2) {
            Some(handle) => notifications(handle),
            None => fail("usage: buyer-client notifications <handle>"),
        },
        _ => fail(
            "usage: buyer-client submit | wait <handle> | run | shortlist | book <handle> <offer_id> <slot_id> | notifications <handle>",
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
