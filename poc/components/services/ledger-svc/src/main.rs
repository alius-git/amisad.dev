// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd POC ledger-svc: append-only hash-chained attestation, settlement,
// and consent ledgers with read APIs and chain verification. Consent entries
// (grant_type participation | contribution, action grant | revoke, keyed by
// a pseudonymous subject hash) fold newest-wins into a per-subject state;
// the chain is the immutable history s003.silence asserts. With
// DATABASE_URL set, every
// append persists to PostgreSQL FIRST (write-through) and the chains reload on
// start, so the ledgers survive pod restarts; without it the store is
// in-memory (tests, skeleton mode). Payloads persist as canonical TEXT - jsonb
// normalization would silently break the hash chain on reload.
// Chain rule: row_hash = sha256(prev_hash_hex + canonical_payload_json),
// genesis prev = 64 zeros. History is never edited; balances are derived.

use amisad_common::{json, serve_app, sha256, Request, Response, ServiceInfo};
use postgres::{Client, NoTls};

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

    /// The (prev, hash) the NEXT append will use - computed without mutating,
    /// so the durable write can happen before the in-memory apply.
    fn next_for(&self, payload: &json::Json) -> (String, String) {
        let prev = self.head();
        let hash = sha256::hex_digest(format!("{prev}{}", payload.dump()).as_bytes());
        (prev, hash)
    }

    fn append(&mut self, payload: json::Json) -> (usize, String) {
        let (prev, hash) = self.next_for(&payload);
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
    consent: Chain,
    instructions: Vec<Instruction>,
    db: Option<Client>,
}

// participation/contribution are the buyer's own consents (s003.silence);
// mandate is a delegated-authority grant (s006.mandate). All three fold the
// same grant/revoke way and share the immutable consent chain.
const GRANT_TYPES: [&str; 3] = ["participation", "contribution", "mandate"];

/// Newest-wins fold of one subject's consent entries for one grant type:
/// "granted", "revoked", or "none" (no entry - the coordinator decides the
/// default policy; the ledger only reports facts).
fn consent_state(chain: &Chain, subject: &str, grant_type: &str) -> &'static str {
    let mut state = "none";
    for entry in &chain.entries {
        if entry.payload.str_of("subject") == Some(subject)
            && entry.payload.str_of("grant_type") == Some(grant_type)
        {
            state = match entry.payload.str_of("action") {
                Some("grant") => "granted",
                Some("revoke") => "revoked",
                _ => state,
            };
        }
    }
    state
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
            eprintln!("ledger-svc: DATABASE_URL set but connection failed: {e}");
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
        eprintln!("ledger-svc: {what}: connection lost ({e}); exiting to reload");
        std::process::exit(1);
    }
    Response::error(503, &format!("{what} unavailable: {e}"))
}

fn load_chain(db: &mut Client, table: &str) -> Chain {
    let query = format!("SELECT payload, prev_hash, row_hash FROM {table} ORDER BY id");
    let rows = db.query(query.as_str(), &[]).unwrap_or_else(|e| {
        eprintln!("ledger-svc: loading {table} failed: {e}");
        std::process::exit(1);
    });
    let mut chain = Chain::default();
    for row in rows {
        let payload_text: String = row.get(0);
        let payload = json::parse(&payload_text).unwrap_or_else(|e| {
            eprintln!("ledger-svc: WARNING {table} row payload unparseable ({e}): {payload_text}");
            json::Json::Null
        });
        chain.entries.push(Entry {
            payload,
            prev: row.get(1),
            hash: row.get(2),
        });
    }
    // A non-verifying chain still serves: /v1/verify is how tampering surfaces.
    if !chain.verify() {
        eprintln!("ledger-svc: WARNING {table} does not verify (see /v1/verify)");
    }
    chain
}

fn load_instructions(db: &mut Client) -> Vec<Instruction> {
    let rows = db
        .query(
            "SELECT match_id, value_cents, splits, confirmed FROM ledger.settlement_instructions",
            &[],
        )
        .unwrap_or_else(|e| {
            eprintln!("ledger-svc: loading settlement_instructions failed: {e}");
            std::process::exit(1);
        });
    rows.iter()
        .map(|row| {
            let splits_text: String = row.get(2);
            let splits = json::parse(&splits_text)
                .ok()
                .and_then(|j| j.as_arr().cloned())
                .unwrap_or_default()
                .iter()
                .map(|s| {
                    (
                        s.str_of("party").unwrap_or("").to_string(),
                        s.i64_of("amount_cents").unwrap_or(0),
                    )
                })
                .collect();
            Instruction {
                match_id: row.get(0),
                value_cents: row.get(1),
                splits,
                confirmed: row.get(3),
            }
        })
        .collect()
}

fn splits_dump(splits: &[(String, i64)]) -> String {
    json::arr(
        splits
            .iter()
            .map(|(party, amount)| {
                json::obj(vec![
                    ("party", json::s(party)),
                    ("amount_cents", json::n(*amount)),
                ])
            })
            .collect(),
    )
    .dump()
}

const PARTIES: [&str; 4] = ["seller_cents", "network_cents", "platform_cents", "ads_cents"];
// s005.attribution: a campaign-boosted match replaces the single "ads" slice
// with agency + creator credit. The party set is chosen by which keys the
// instruction carries; every present slice must sum to value_cents.
const AD_CREDIT_PARTIES: [&str; 5] =
    ["seller_cents", "network_cents", "platform_cents", "agency_cents", "creator_cents"];

fn parse_instruction(body: &json::Json) -> Result<Instruction, String> {
    let match_id = body
        .str_of("match_id")
        .ok_or("match_id required")?
        .to_string();
    let value_cents = body.i64_of("value_cents").ok_or("value_cents required")?;
    let splits_obj = body.get("splits").ok_or("splits required")?;
    let parties: &[&str] = if splits_obj.get("agency_cents").is_some() {
        &AD_CREDIT_PARTIES
    } else {
        &PARTIES
    };
    let mut splits = Vec::new();
    let mut total = 0i64;
    for party in parties {
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
            if let Some(db) = state.db.as_mut() {
                let (prev, hash) = state.attestation.next_for(&body);
                let env_id = body.str_of("environment_id").unwrap_or("").to_string();
                let lifecycle = body.str_of("lifecycle").unwrap_or("").to_string();
                if let Err(e) = db.execute(
                    "INSERT INTO ledger.attestation_ledger (environment_id, lifecycle, payload, prev_hash, row_hash) VALUES ($1, $2, $3, $4, $5)",
                    &[&env_id, &lifecycle, &body.dump(), &prev, &hash],
                ) {
                    return store_error(db, "attestation store", e);
                }
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
            if let Some(db) = state.db.as_mut() {
                if let Err(e) = db.execute(
                    "INSERT INTO ledger.settlement_instructions (match_id, value_cents, splits, confirmed) VALUES ($1, $2, $3, false)",
                    &[&instruction.match_id, &instruction.value_cents, &splits_dump(&instruction.splits)],
                ) {
                    return store_error(db, "instruction store", e);
                }
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
            let index = match state.instructions.iter().position(|i| i.match_id == match_id) {
                Some(i) => i,
                None => return Response::error(404, "no instruction for match_id"),
            };
            if state.instructions[index].confirmed {
                return Response::error(409, "already confirmed");
            }
            // Precompute the whole chain extension, persist it as ONE
            // transaction (confirmed flag + all splits), and only then apply
            // to memory - a mid-confirm failure leaves nothing half-settled.
            let splits = state.instructions[index].splits.clone();
            let mut prepared = Vec::new();
            let mut prev = state.settlement.head();
            for (party, amount) in &splits {
                let payload = json::obj(vec![
                    ("match_id", json::s(&match_id)),
                    ("party", json::s(party)),
                    ("amount_cents", json::n(*amount)),
                ]);
                let hash = sha256::hex_digest(format!("{prev}{}", payload.dump()).as_bytes());
                prepared.push((payload, prev.clone(), hash.clone()));
                prev = hash;
            }
            if let Some(db) = state.db.as_mut() {
                let persisted = (|| {
                    let mut tx = db.transaction()?;
                    tx.execute(
                        "UPDATE ledger.settlement_instructions SET confirmed = true WHERE match_id = $1",
                        &[&match_id],
                    )?;
                    for (payload, entry_prev, entry_hash) in &prepared {
                        tx.execute(
                            "INSERT INTO ledger.settlement_ledger (match_id, entry_type, payload, prev_hash, row_hash) VALUES ($1, 'split', $2, $3, $4)",
                            &[&match_id, &payload.dump(), entry_prev, entry_hash],
                        )?;
                    }
                    tx.commit()
                })();
                if let Err(e) = persisted {
                    return store_error(db, "settlement store", e);
                }
            }
            state.instructions[index].confirmed = true;
            for (payload, _, _) in prepared {
                state.settlement.append(payload);
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
        ("POST", "/v1/consents") => {
            let body = match json::parse(&req.body) {
                Ok(b) => b,
                Err(e) => return Response::error(400, &e),
            };
            let grant_type = body.str_of("grant_type").unwrap_or("");
            let action = body.str_of("action").unwrap_or("");
            if body.str_of("subject").is_none()
                || !GRANT_TYPES.contains(&grant_type)
                || !matches!(action, "grant" | "revoke")
                || body.i64_of("ts").is_none()
            {
                return Response::error(
                    400,
                    "subject, grant_type (participation|contribution|mandate), action (grant|revoke), ts required",
                );
            }
            if let Some(db) = state.db.as_mut() {
                let (prev, hash) = state.consent.next_for(&body);
                let grant_type = grant_type.to_string();
                if let Err(e) = db.execute(
                    "INSERT INTO ledger.consent_ledger (grant_type, payload, prev_hash, row_hash) VALUES ($1, $2, $3, $4)",
                    &[&grant_type, &body.dump(), &prev, &hash],
                ) {
                    return store_error(db, "consent store", e);
                }
            }
            let (index, hash) = state.consent.append(body);
            Response::json(
                201,
                &json::obj(vec![("index", json::n(index as i64)), ("hash", json::s(&hash))]),
            )
        }
        ("GET", "/v1/verify") => Response::json(
            200,
            &json::obj(vec![
                ("attestation_ok", json::b(state.attestation.verify())),
                ("settlement_ok", json::b(state.settlement.verify())),
                ("consent_ok", json::b(state.consent.verify())),
                ("attestation_len", json::n(state.attestation.entries.len() as i64)),
                ("settlement_len", json::n(state.settlement.entries.len() as i64)),
                ("consent_len", json::n(state.consent.entries.len() as i64)),
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
            if let ("GET", Some(subject)) =
                (req.method.as_str(), path.strip_prefix("/v1/consents/subject/"))
            {
                let history: Vec<json::Json> = state
                    .consent
                    .entries
                    .iter()
                    .filter(|e| e.payload.str_of("subject") == Some(subject))
                    .map(|e| e.payload.clone())
                    .collect();
                return Response::json(
                    200,
                    &json::obj(vec![
                        ("subject", json::s(subject)),
                        (
                            "participation",
                            json::s(consent_state(&state.consent, subject, "participation")),
                        ),
                        (
                            "contribution",
                            json::s(consent_state(&state.consent, subject, "contribution")),
                        ),
                        ("history", json::arr(history)),
                    ]),
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
    let mut db = open_db();
    let (attestation, settlement, consent, instructions) = match db.as_mut() {
        Some(client) => (
            load_chain(client, "ledger.attestation_ledger"),
            load_chain(client, "ledger.settlement_ledger"),
            load_chain(client, "ledger.consent_ledger"),
            load_instructions(client),
        ),
        None => (Chain::default(), Chain::default(), Chain::default(), Vec::new()),
    };
    serve_app(
        ServiceInfo {
            name: "ledger-svc",
            version: env!("CARGO_PKG_VERSION"),
        },
        State {
            attestation,
            settlement,
            consent,
            instructions,
            db,
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
    fn consent_fold_is_newest_wins_per_subject_and_type() {
        let mut chain = Chain::default();
        let entry = |subject: &str, grant_type: &str, action: &str| {
            json::obj(vec![
                ("subject", json::s(subject)),
                ("grant_type", json::s(grant_type)),
                ("action", json::s(action)),
                ("ts", json::n(1)),
            ])
        };
        assert_eq!(consent_state(&chain, "s1", "participation"), "none");
        chain.append(entry("s1", "participation", "grant"));
        chain.append(entry("s1", "contribution", "grant"));
        chain.append(entry("s2", "participation", "grant"));
        chain.append(entry("s1", "participation", "revoke"));
        assert_eq!(consent_state(&chain, "s1", "participation"), "revoked");
        assert_eq!(consent_state(&chain, "s1", "contribution"), "granted");
        assert_eq!(consent_state(&chain, "s2", "participation"), "granted");
        chain.append(entry("s1", "participation", "grant"));
        assert_eq!(consent_state(&chain, "s1", "participation"), "granted");
        assert!(chain.verify());
    }

    #[test]
    fn splits_round_trip_through_canonical_dump() {
        // Guards the persistence format: load_instructions parses what
        // splits_dump wrote, preserving party order and amounts.
        let splits = vec![
            ("seller".to_string(), 10800i64),
            ("network".to_string(), 600),
            ("platform".to_string(), 600),
            ("ads".to_string(), 0),
        ];
        let parsed = json::parse(&splits_dump(&splits)).unwrap();
        let back: Vec<(String, i64)> = parsed
            .as_arr()
            .unwrap()
            .iter()
            .map(|s| {
                (
                    s.str_of("party").unwrap().to_string(),
                    s.i64_of("amount_cents").unwrap(),
                )
            })
            .collect();
        assert_eq!(back, splits);
    }

    #[test]
    fn confirm_appends_entries_summing_to_value() {
        let mut state = State {
            attestation: Chain::default(),
            settlement: Chain::default(),
            consent: Chain::default(),
            instructions: Vec::new(),
            db: None,
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
