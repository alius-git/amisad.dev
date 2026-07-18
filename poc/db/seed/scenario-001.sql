-- AmisAd POC - SCENARIO-001 seed: Elena's catalog with standing auto-close
-- deals in region-a.
--
-- NOTE: the live scenario sequence seeds these via the seller-svc API today,
-- because the services keep in-memory state pending the PostgreSQL wiring
-- (deviation noted in poc/README.md). This file is the same seed expressed
-- against db/schema.sql, so the API seeding retires when PG lands.

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
