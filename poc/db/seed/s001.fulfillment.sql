-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC - s001.fulfillment seed: Elena's catalog with standing auto-close
-- deals in region-a. NOTE: the live sequence seeds via the seller-svc API,
-- which WRITES THROUGH to PostgreSQL (offers persist with their full document
-- JSON) - API seeding stays canonical. This file is the relational sketch of
-- the same seed, for direct-SQL use.

INSERT INTO seller.offers
    (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close)
VALUES
    ('serving-set-01', 'elena-atelier', 'Ceramic serving set', 'housewares',
     'region-a', 11000, 10, true),
    ('crystal-vase-02', 'elena-atelier', 'Crystal vase', 'housewares',
     'region-a', 15000, 5, true)
ON CONFLICT (offer_id) DO NOTHING;

-- Maya's participation consent is a hash-chained ledger append (grant_type
-- 'participation'); chained rows cannot be seeded with plain INSERTs without
-- computing row hashes, so consent seeding stays with ledger-svc.
