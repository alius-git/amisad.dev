// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 alius-git
// AmisAd POC buyer-client: the headless buyer driving SCENARIO-001's happy
// path (plays Maya - poc/README.md "SCENARIO-001 implementation notes"). The
// need JSON deliberately contains no identity fields - the token
// authenticates, the need describes. Usage: submit (print match as one JSON
// line) | wait <handle> (poll until delivered; exit 1 on timeout) | run.

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

/// Maya's SCENARIO-001 need: wish-list gift, budget cap, delivery deadline,
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

fn fail(message: &str) -> ! {
    eprintln!("buyer-client: {message}");
    exit(1)
}

fn submit() -> json::Json {
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
        ("envelope", json::s(&need_json().dump())),
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
        _ => fail("usage: buyer-client submit | wait <handle> | run"),
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
}
