-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC - s005.attribution seed: Campaign-Boosted Match, Edge Creative
-- Serving, and Attribution Credit.
-- NOTE: the live sequence seeds via the APIs. The ad economy is operational
-- state, not relational: campaigns, briefs, assets, and attribution live in
-- ads-svc (in-memory), and the boosted settlement's agency/creator split is
-- hash-chained on the settlement ledger. Only Elena's offer is relational:

INSERT INTO seller.offers
    (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close)
VALUES
    ('serving-set-01', 'elena-atelier', 'Ceramic serving set', 'housewares',
     'region-a', 11000, 10, true)
ON CONFLICT (offer_id) DO NOTHING;
