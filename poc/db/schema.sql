-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 alius-git
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
-- Skeleton: shape only; constraints and derivations land with the scenarios.
CREATE TABLE IF NOT EXISTS ledger.consent_ledger (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    grant_type  text        NOT NULL, -- participation | mandate | disclosure
    payload     jsonb       NOT NULL,
    prev_hash   bytea       NOT NULL,
    row_hash    bytea       NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ledger.settlement_ledger (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    match_id    uuid        NOT NULL,
    entry_type  text        NOT NULL, -- split | adjustment
    payload     jsonb       NOT NULL,
    prev_hash   bytea       NOT NULL,
    row_hash    bytea       NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ledger.attestation_ledger (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    environment_id uuid        NOT NULL,
    lifecycle      text        NOT NULL, -- created | attested | executed | aborted | destroyed
    payload        jsonb       NOT NULL,
    prev_hash      bytea       NOT NULL,
    row_hash       bytea       NOT NULL,
    created_at     timestamptz NOT NULL DEFAULT now()
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

-- Seller tables (landed with SCENARIO-001; see db/seed/scenario-001.sql).
CREATE TABLE IF NOT EXISTS seller.offers (
    offer_id        text PRIMARY KEY,
    tenant          text        NOT NULL,
    title           text        NOT NULL,
    category        text        NOT NULL,
    region          text        NOT NULL,
    price_cents     bigint      NOT NULL CHECK (price_cents >= 0),
    deliver_by_days integer,
    auto_close      boolean     NOT NULL DEFAULT false,
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
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- TODO: remaining per-service tables land with their scenarios (see db/seed/*.sql).
