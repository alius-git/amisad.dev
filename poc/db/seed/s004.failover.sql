-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC - s004.failover seed: Sovereign Slice Allocation, Isolation
-- Fault, and Attested Failover.
-- NOTE: the live sequence seeds via the APIs. The scenario's real state is
-- operational, not relational: edges with capacity and the jurisdiction
-- policy live in resource-svc (in-memory control plane), faults are armed on
-- slice-runtime, and the aborted/completed lifecycles land as hash-chained
-- attestation rows (cannot be seeded with plain INSERTs). Only the catalog
-- is relational:

INSERT INTO seller.offers
    (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close)
VALUES
    ('serving-set-01', 'elena-atelier', 'Ceramic serving set', 'housewares',
     'region-a', 11000, 10, true)
ON CONFLICT (offer_id) DO NOTHING;
