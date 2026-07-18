-- AmisAd POC database schema (skeleton).
-- One PostgreSQL instance, one schema per service (plan/design.md §1).
-- Ledgers are append-only, hash-chained tables (no blockchain): every row
-- carries the sha256 of the previous row's hash + its own payload; balances
-- and views are derived, never edited.

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

-- TODO: per-service tables land with their scenarios (see db/seed/*.sql).
