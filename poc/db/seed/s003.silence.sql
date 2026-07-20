-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC - s003.silence seed: Consent Revocation and the Right to Silence.
-- NOTE: the live sequence seeds via the APIs, which write through to
-- PostgreSQL. Consent entries are hash-chained rows (prev_hash/row_hash) and
-- CANNOT be seeded with plain INSERTs without computing the chain - grants,
-- revocations, and re-grants go through ledger-svc POST /v1/consents (via the
-- coordinator, which derives the pseudonymous subject). This file sketches
-- only the relational side: the catalog present when the scenario starts,
-- plus the perfectly-fitting offer brisa-outlet publishes DURING the pause.

INSERT INTO seller.offers
    (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close)
VALUES
    ('serving-set-01', 'elena-atelier', 'Ceramic serving set', 'housewares',
     'region-a', 11000, 10, true),
    ('crystal-vase-02', 'elena-atelier', 'Crystal vase', 'housewares',
     'region-a', 15000, 5, true)
ON CONFLICT (offer_id) DO NOTHING;

-- NOT part of the start state: brisa-outlet's 'linen-wrap-09' (dresses,
-- region-a, 13000, deliver 2, auto_close, attributes midi/sleeves/warm-
-- fabric) is published DURING the pause - seeding it up front would match
-- the open dress need at submit time and collapse the scenario's premise.
