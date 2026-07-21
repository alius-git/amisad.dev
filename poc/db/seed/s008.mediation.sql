-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC - s008.mediation seed: Zero-Knowledge Dispute Mediation and
-- Settlement Adjustment.
-- NOTE: the live sequence seeds via the APIs. The dispute is operational -
-- the support case + time-boxed disclosure live in platform-svc, the refund
-- posts as hash-chained compensating settlement entries. Only Elena's offer
-- (the disputed order's) is relational:

INSERT INTO seller.offers
    (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close)
VALUES
    ('serving-set-01', 'elena-atelier', 'Ceramic serving set', 'housewares',
     'region-a', 11000, 10, true)
ON CONFLICT (offer_id) DO NOTHING;
