// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC identity-mock: OIDC-style token issuer standing in for
// Identity & Verification. Issues opaque tokens per actor and verifies them.
// s001.fulfillment uses it for the buyer actor; seller authentication is deferred.

use amisad_common::{json, serve_app, sha256, Request, Response, ServiceInfo};
use std::time::{SystemTime, UNIX_EPOCH};

struct State {
    tokens: Vec<(String, String, String)>, // (token, actor, class)
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

fn handle(state: &mut State, req: &Request) -> Response {
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/v1/tokens") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let actor = match body.str_of("actor") {
                Some(a) => a.to_string(),
                None => return Response::error(400, "actor required"),
            };
            let class = body.str_of("class").unwrap_or("person").to_string();
            let token = sha256::hex_digest(format!("{actor}|{class}|{}", now_nanos()).as_bytes());
            state.tokens.push((token.clone(), actor, class));
            Response::json(201, &json::obj(vec![("token", json::s(&token))]))
        }
        ("POST", "/v1/verify") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let token = body.str_of("token").unwrap_or("");
            match state.tokens.iter().find(|(t, _, _)| t == token) {
                Some((_, actor, class)) => Response::json(
                    200,
                    &json::obj(vec![("actor", json::s(actor)), ("class", json::s(class))]),
                ),
                None => Response::error(404, "unknown token"),
            }
        }
        _ => Response::error(404, "not found"),
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "identity-mock",
            version: env!("CARGO_PKG_VERSION"),
        },
        State { tokens: Vec::new() },
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
    fn issue_then_verify() {
        let mut state = State { tokens: Vec::new() };
        let issued = handle(
            &mut state,
            &req("POST", "/v1/tokens", "{\"actor\":\"maya\",\"class\":\"person\"}"),
        );
        assert_eq!(issued.status, 201);
        let token = json::parse(&issued.body)
            .unwrap()
            .str_of("token")
            .unwrap()
            .to_string();
        let verified = handle(
            &mut state,
            &req("POST", "/v1/verify", &format!("{{\"token\":\"{token}\"}}")),
        );
        assert_eq!(verified.status, 200);
        assert_eq!(
            json::parse(&verified.body).unwrap().str_of("actor"),
            Some("maya")
        );
        let unknown = handle(&mut state, &req("POST", "/v1/verify", "{\"token\":\"nope\"}"));
        assert_eq!(unknown.status, 404);
    }
}
