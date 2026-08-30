-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC database schema (skeleton): one PostgreSQL instance, one schema
-- per stateful service (plan/design.md section 1; fabric-coordinator is a
-- stateless router and has none). Ledgers are append-only, hash-chained
-- tables (no blockchain): every row carries the sha256 of the previous row's
-- hash + its own payload; balances and views are derived, never edited.

CREATE SCHEMA IF NOT EXISTS seller;
CREATE SCHEMA IF NOT EXISTS resource;
CREATE SCHEMA IF NOT EXISTS ads;
CREATE SCHEMA IF NOT EXISTS insights;
CREATE SCHEMA IF NOT EXISTS platform;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS connect;
CREATE SCHEMA IF NOT EXISTS identity;
CREATE SCHEMA IF NOT EXISTS ledger;

-- Hash-chained ledger families (consent, settlement, attestation).
-- payload is the CANONICAL service JSON as text, and hashes are sha256 hex
-- text: row_hash = sha256(prev_hash || payload). jsonb would normalize key
-- order and silently break chain verification on reload. Ids are text because
-- POC match/environment ids are sha256 hex digests, not uuids.
-- UNIQUE (prev_hash): each head is consumed exactly once, so a would-be
-- fork (two writers, or a retry after an ambiguous connection error) is a
-- hard insert failure instead of a silently non-verifying chain.
CREATE TABLE IF NOT EXISTS ledger.consent_ledger (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    grant_type  text        NOT NULL, -- participation | contribution | mandate | disclosure
    payload     text        NOT NULL, -- {subject, grant_type, action, ts}; subject is a pseudonymous hash
    prev_hash   text        NOT NULL UNIQUE,
    row_hash    text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ledger.settlement_ledger (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    match_id    text        NOT NULL,
    entry_type  text        NOT NULL, -- split | adjustment
    payload     text        NOT NULL,
    prev_hash   text        NOT NULL UNIQUE,
    row_hash    text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ledger.attestation_ledger (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    environment_id text        NOT NULL,
    lifecycle      text        NOT NULL, -- created | attested | executed | aborted | destroyed
    payload        text        NOT NULL,
    prev_hash      text        NOT NULL UNIQUE,
    row_hash       text        NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- Pending/confirmed settlement instructions (ledger-svc working state; the
-- immutable record of confirmed splits is settlement_ledger above).
CREATE TABLE IF NOT EXISTS ledger.settlement_instructions (
    match_id    text PRIMARY KEY,
    value_cents bigint      NOT NULL CHECK (value_cents >= 0),
    splits      text        NOT NULL, -- canonical JSON [{party, amount_cents}]
    confirmed   boolean     NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Read-only role for audit-svc: independence is architectural.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'amisad_audit_ro') THEN
        CREATE ROLE amisad_audit_ro NOLOGIN;
    END IF;
END
$$;
GRANT USAGE ON SCHEMA ledger TO amisad_audit_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA ledger TO amisad_audit_ro;

-- Seller tables (landed with s001.fulfillment; see db/seed/s001.fulfillment.sql).
CREATE TABLE IF NOT EXISTS seller.offers (
    offer_id        text PRIMARY KEY,
    tenant          text        NOT NULL,
    title           text        NOT NULL,
    category        text        NOT NULL,
    region          text        NOT NULL,
    price_cents     bigint      NOT NULL CHECK (price_cents >= 0),
    deliver_by_days integer,
    auto_close      boolean     NOT NULL DEFAULT false,
    -- Full offer JSON as posted (canonical text): carries the s002.fitting
    -- attributes and fitting_slots until those grow relational tables.
    document        text        NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- Orders carry need context only; there is deliberately no buyer identity
-- column - the privacy constraint is the schema.
CREATE TABLE IF NOT EXISTS seller.orders (
    match_id     text PRIMARY KEY,
    offer_id     text        NOT NULL REFERENCES seller.offers (offer_id),
    tenant       text        NOT NULL,
    need_context text        NOT NULL DEFAULT '',
    state        text        NOT NULL DEFAULT 'committed'
        CHECK (state IN ('committed', 'provisioning', 'fulfilled', 'settled')),
    -- In-person booking (s002.fitting): appointment slot, empty when none.
    slot_id      text        NOT NULL DEFAULT '',
    slot_day     text        NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
