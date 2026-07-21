-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC - s006.mandate seed: Delegated Procurement Under a Scoped
-- Mandate.
-- NOTE: the live sequence seeds via the APIs. The mandate grant/revoke is a
-- hash-chained consent-ledger append (grant_type 'mandate', pseudonymous
-- principal + delegate subjects) that cannot be seeded with plain INSERTs;
-- the coordinator's delegate state is in-memory. Only Elena's offers are
-- relational (a staple under the cap, a premium item over it):

INSERT INTO seller.offers
    (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close)
VALUES
    ('serving-set-01', 'elena-atelier', 'Ceramic serving set', 'housewares',
     'region-a', 11000, 10, false),
    ('premium-vase-06', 'elena-atelier', 'Premium crystal vase', 'housewares',
     'region-a', 18000, 10, false)
ON CONFLICT (offer_id) DO NOTHING;
