-- LICENSEURI https://yuruna.link/license
-- Copyright (c) 2026 by Alisson Sol et al.
-- AmisAd POC - s002.fitting seed: Elena's dress catalog (one dusty blue), a
-- second seller's out-of-range/past-deadline dresses, and fitting slots.
-- NOTE: the live sequence seeds via the seller-svc API, which now WRITES
-- THROUGH to PostgreSQL; attributes and fitting slots ride in the persisted
-- offer document (seller.offers.document) and land in relational form when
-- the schema grows offer_attributes/fitting_slots tables.

INSERT INTO seller.offers
    (offer_id, tenant, title, category, region, price_cents, deliver_by_days, auto_close)
VALUES
    -- Qualifying: midi + sleeves + warm fabric, Thursday slot (thu-1).
    ('linen-midi-04', 'elena-atelier', 'Linen midi dress', 'dresses',
     'region-a', 18000, 3, false),
    -- Excluded color; cheaper than the qualifying dress so its absence from
    -- the shortlist proves the exclusion decided, not the price.
    ('dusty-blue-02', 'elena-atelier', 'Dusty blue midi dress', 'dresses',
     'region-a', 16000, 3, false),
    -- Missing required attributes (sleeveless, no warm fabric).
    ('silk-slip-03', 'elena-atelier', 'Silk slip dress', 'dresses',
     'region-a', 15000, 3, false),
    -- Second seller: past the deadline, and out of range.
    ('wool-midi-07', 'brisa-outlet', 'Wool midi dress', 'dresses',
     'region-a', 14000, 30, false),
    ('linen-wrap-08', 'brisa-outlet', 'Linen wrap dress', 'dresses',
     'region-b', 13000, 2, false)
ON CONFLICT (offer_id) DO NOTHING;

-- Maya's participation consent is a hash-chained ledger append; chained rows
-- cannot be seeded with plain INSERTs, so consent seeding stays with ledger-svc.
