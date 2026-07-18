// AmisAd POC ledger-svc: append-only hash-chained attestation and settlement
// ledgers with read APIs and chain verification. In-memory for SCENARIO-001;
// the PostgreSQL wiring behind the same API is a noted deviation (poc/README).
//
// Chain rule: row_hash = sha256(prev_hash_hex + canonical_payload_json),
// genesis prev = 64 zeros. History is never edited; balances are derived.

use amisad_common::{json, serve_app, sha256, Request, Response, ServiceInfo};

const GENESIS: &str = "0000000000000000000000000000000000000000000000000000000000000000";

struct Entry {
    payload: json::Json,
    prev: String,
    hash: String,
}

#[derive(Default)]
struct Chain {
    entries: Vec<Entry>,
}

impl Chain {
    fn head(&self) -> String {
        self.entries
            .last()
            .map(|e| e.hash.clone())
            .unwrap_or_else(|| GENESIS.to_string())
    }

    fn append(&mut self, payload: json::Json) -> (usize, String) {
        let prev = self.head();
        let hash = sha256::hex_digest(format!("{prev}{}", payload.dump()).as_bytes());
        self.entries.push(Entry {
            payload,
            prev,
            hash: hash.clone(),
        });
        (self.entries.len() - 1, hash)
    }

    fn verify(&self) -> bool {
        let mut prev = GENESIS.to_string();
        for entry in &self.entries {
            if entry.prev != prev {
                return false;
            }
            let hash = sha256::hex_digest(format!("{prev}{}", entry.payload.dump()).as_bytes());
            if hash != entry.hash {
                return false;
            }
            prev = entry.hash.clone();
        }
        true
    }

    fn dump_entries(&self) -> json::Json {
        json::arr(
            self.entries
                .iter()
                .map(|e| {
                    json::obj(vec![
                        ("payload", e.payload.clone()),
                        ("prev", json::s(&e.prev)),
                        ("hash", json::s(&e.hash)),
                    ])
                })
                .collect(),
        )
    }
}

struct Instruction {
    match_id: String,
    value_cents: i64,
    splits: Vec<(String, i64)>,
    confirmed: bool,
}

struct State {
    attestation: Chain,
    settlement: Chain,
    instructions: Vec<Instruction>,
}

const PARTIES: [&str; 4] = ["seller_cents", "network_cents", "platform_cents", "ads_cents"];

fn parse_instruction(body: &json::Json) -> Result<Instruction, String> {
    let match_id = body
        .str_of("match_id")
        .ok_or("match_id required")?
        .to_string();
    let value_cents = body.i64_of("value_cents").ok_or("value_cents required")?;
    let splits_obj = body.get("splits").ok_or("splits required")?;
    let mut splits = Vec::new();
    let mut total = 0i64;
    for party in PARTIES {
        let amount = splits_obj
            .i64_of(party)
            .ok_or_else(|| format!("splits.{party} required"))?;
        if amount < 0 {
            return Err(format!("splits.{party} negative"));
        }
        total += amount;
        splits.push((party.trim_end_matches("_cents").to_string(), amount));
    }
    if total != value_cents {
        return Err(format!("splits sum {total} != value_cents {value_cents}"));
    }
    Ok(Instruction {
        match_id,
        value_cents,
        splits,
        confirmed: false,
    })
}

fn handle(state: &mut State, req: &Request) -> Response {
    let path = req.path.as_str();
    match (req.method.as_str(), path) {
        ("POST", "/v1/attestations") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            if body.str_of("environment_id").is_none() || body.str_of("lifecycle").is_none() {
                return Response::error(400, "environment_id and lifecycle required");
            }
            let (index, hash) = state.attestation.append(body);
            Response::json(
                201,
                &json::obj(vec![("index", json::n(index as i64)), ("hash", json::s(&hash))]),
            )
        }
        ("GET", "/v1/attestations") => Response::json(
            200,
            &json::obj(vec![
                ("entries", state.attestation.dump_entries()),
                ("head", json::s(&state.attestation.head())),
            ]),
        ),
        ("POST", "/v1/settlements/instructions") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let instruction = match parse_instruction(&body) {
                Ok(i) => i,
                Err(e) => return Response::error(400, &e),
            };
            if state
                .instructions
                .iter()
                .any(|i| i.match_id == instruction.match_id)
            {
                return Response::error(409, "instruction exists for match_id");
            }
            let match_id = instruction.match_id.clone();
            state.instructions.push(instruction);
            Response::json(
                201,
                &json::obj(vec![
                    ("match_id", json::s(&match_id)),
                    ("status", json::s("pending")),
                ]),
            )
        }
        ("POST", "/v1/settlements/confirm") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let match_id = body.str_of("match_id").unwrap_or("").to_string();
            let instruction = match state
                .instructions
                .iter_mut()
                .find(|i| i.match_id == match_id)
            {
                Some(i) => i,
                None => return Response::error(404, "no instruction for match_id"),
            };
            if instruction.confirmed {
                return Response::error(409, "already confirmed");
            }
            instruction.confirmed = true;
            let splits = instruction.splits.clone();
            for (party, amount) in &splits {
                state.settlement.append(json::obj(vec![
                    ("match_id", json::s(&match_id)),
                    ("party", json::s(party)),
                    ("amount_cents", json::n(*amount)),
                ]));
            }
            Response::json(
                201,
                &json::obj(vec![
                    ("match_id", json::s(&match_id)),
                    ("entries", json::n(splits.len() as i64)),
                    ("head", json::s(&state.settlement.head())),
                ]),
            )
        }
        ("GET", "/v1/verify") => Response::json(
            200,
            &json::obj(vec![
                ("attestation_ok", json::b(state.attestation.verify())),
                ("settlement_ok", json::b(state.settlement.verify())),
                ("attestation_len", json::n(state.attestation.entries.len() as i64)),
                ("settlement_len", json::n(state.settlement.entries.len() as i64)),
            ]),
        ),
        _ => {
            if let ("GET", Some(env_id)) =
                (req.method.as_str(), path.strip_prefix("/v1/attestations/env/"))
            {
                let entries: Vec<json::Json> = state
                    .attestation
                    .entries
                    .iter()
                    .filter(|e| e.payload.str_of("environment_id") == Some(env_id))
                    .map(|e| e.payload.clone())
                    .collect();
                return Response::json(
                    200,
                    &json::obj(vec![("entries", json::arr(entries))]),
                );
            }
            if let ("GET", Some(match_id)) =
                (req.method.as_str(), path.strip_prefix("/v1/settlements/match/"))
            {
                let instruction = state.instructions.iter().find(|i| i.match_id == match_id);
                let entries: Vec<json::Json> = state
                    .settlement
                    .entries
                    .iter()
                    .filter(|e| e.payload.str_of("match_id") == Some(match_id))
                    .map(|e| e.payload.clone())
                    .collect();
                let total: i64 = entries
                    .iter()
                    .filter_map(|e| e.i64_of("amount_cents"))
                    .sum();
                return Response::json(
                    200,
                    &json::obj(vec![
                        ("match_id", json::s(match_id)),
                        (
                            "value_cents",
                            instruction.map(|i| json::n(i.value_cents)).unwrap_or(json::Json::Null),
                        ),
                        (
                            "confirmed",
                            json::b(instruction.map(|i| i.confirmed).unwrap_or(false)),
                        ),
                        ("entries", json::arr(entries)),
                        ("total_cents", json::n(total)),
                    ]),
                );
            }
            Response::error(404, "not found")
        }
    }
}

fn main() -> std::io::Result<()> {
    serve_app(
        ServiceInfo {
            name: "ledger-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            attestation: Chain::default(),
            settlement: Chain::default(),
            instructions: Vec::new(),
        },
        handle,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chain_appends_and_verifies() {
        let mut chain = Chain::default();
        chain.append(json::obj(vec![("a", json::n(1))]));
        chain.append(json::obj(vec![("b", json::n(2))]));
        assert!(chain.verify());
        assert_eq!(chain.entries[1].prev, chain.entries[0].hash);
    }

    #[test]
    fn tamper_is_detected() {
        let mut chain = Chain::default();
        chain.append(json::obj(vec![("amount", json::n(100))]));
        chain.append(json::obj(vec![("amount", json::n(200))]));
        chain.entries[0].payload = json::obj(vec![("amount", json::n(999))]);
        assert!(!chain.verify());
    }

    #[test]
    fn instruction_sum_must_match_value() {
        let good = json::parse(
            "{\"match_id\":\"m1\",\"value_cents\":10000,\"splits\":{\"seller_cents\":9000,\"network_cents\":500,\"platform_cents\":500,\"ads_cents\":0}}",
        )
        .unwrap();
        assert!(parse_instruction(&good).is_ok());
        let bad = json::parse(
            "{\"match_id\":\"m1\",\"value_cents\":10000,\"splits\":{\"seller_cents\":9000,\"network_cents\":500,\"platform_cents\":400,\"ads_cents\":0}}",
        )
        .unwrap();
        assert!(parse_instruction(&bad).is_err());
    }

    #[test]
    fn confirm_appends_entries_summing_to_value() {
        let mut state = State {
            attestation: Chain::default(),
            settlement: Chain::default(),
            instructions: Vec::new(),
        };
        let inst = json::parse(
            "{\"match_id\":\"m1\",\"value_cents\":12000,\"splits\":{\"seller_cents\":10800,\"network_cents\":600,\"platform_cents\":600,\"ads_cents\":0}}",
        )
        .unwrap();
        state.instructions.push(parse_instruction(&inst).unwrap());
        let confirm = Request {
            method: "POST".to_string(),
            path: "/v1/settlements/confirm".to_string(),
            body: "{\"match_id\":\"m1\"}".to_string(),
        };
        let response = handle(&mut state, &confirm);
        assert_eq!(response.status, 201);
        let total: i64 = state
            .settlement
            .entries
            .iter()
            .filter_map(|e| e.payload.i64_of("amount_cents"))
            .sum();
        assert_eq!(total, 12000);
        assert!(state.settlement.verify());
    }
}
