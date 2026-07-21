-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC - s007.inventory seed: Enterprise Integration Onboarding and
-- Inventory-Truth Matching.
-- NOTE: the live sequence seeds via the connector APIs. Partners, scoped
-- credentials, inventory deltas, ERP mirror, and the audit log live in
-- connect-svc (in-memory); the catalog is synced into seller-svc through the
-- gateway. This is the equivalent relational catalog (erp-lamp-01 is the
-- unit the external sale zeroes; erp-clock-02 is the in-stock alternative):

INSERT INTO seller.offers
    (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close)
VALUES
    ('erp-lamp-01', 'elena-atelier', 'ERP table lamp', 'housewares',
     'region-a', 8000, 5, true),
    ('erp-clock-02', 'elena-atelier', 'ERP wall clock', 'housewares',
     'region-a', 9000, 5, true)
ON CONFLICT (offer_id) DO NOTHING;
