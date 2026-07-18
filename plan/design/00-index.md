# AmisAd POC design diagrams

> One sentence: the entry point to the POC design diagrams — what each shows and how they relate to the master design and the planning docs.

Prose design lives in [../design.md](../design.md); the ecosystem definition in [../applications.md](../applications.md); the verification blueprint in [../scenarios.md](../scenarios.md). These documents visualize them, they do not restate them. Every diagram holds at most seven boxes; planned/growth-path items use dashed edges.

## The documents

| # | Document | Diagram type | Shows |
|---|----------|--------------|-------|
| 1 | [POC overview](01-overview.md) | flowchart ×2 | The seven top-level POC blocks; the four-node deployment topology. |
| 2 | [AmisAd/buyer](02-buyer.md) | flowchart | Flutter app internals: vault, matching path, delegate mode. |
| 3 | [AmisAd/seller](03-seller.md) | flowchart | seller-svc: catalog, inventory, order state machine, grants. |
| 4 | [AmisAd/resource](04-resource.md) | flowchart | resource-svc: policy, slice controller, telemetry, incidents. |
| 5 | [AmisAd/ads](05-ads.md) | flowchart | ads-svc: campaign + studio modes, assets, attribution. |
| 6 | [AmisAd/insights](06-insights.md) | flowchart | insights-svc: threshold pipeline, workbench, outlooks. |
| 7 | [AmisAd/platform](07-platform.md) | flowchart | platform-svc: operations + support desk, registry, adjustments. |
| 8 | [AmisAd/audit](08-audit.md) | flowchart | audit-svc: chain verification, certification, reporting. |
| 9 | [AmisAd/connect](09-connect.md) | flowchart | connect-svc: contracts, sandbox, credentials, webhooks. |

## Scenario sequences

One sequence diagram per verification scenario, faithful to the numbered steps in [../scenarios.md](../scenarios.md); participants are the POC components above, personas as actors, at most 8 lifelines each.

| Document | Sequence for |
|----------|--------------|
| [seq-001.md](seq-001.md) | SCENARIO-001 — Intent-Driven Edge Match and Automated Fulfillment |
| [seq-002.md](seq-002.md) | SCENARIO-002 — Considered Purchase, Constraint Fidelity, and In-Person Booking |
| [seq-003.md](seq-003.md) | SCENARIO-003 — Consent Revocation and the Right to Silence |
| [seq-004.md](seq-004.md) | SCENARIO-004 — Sovereign Slice Allocation, Isolation Fault, and Attested Failover |
| [seq-005.md](seq-005.md) | SCENARIO-005 — Campaign-Boosted Match, Edge Creative Serving, and Attribution Credit |
| [seq-006.md](seq-006.md) | SCENARIO-006 — Delegated Procurement Under a Scoped Mandate |
| [seq-007.md](seq-007.md) | SCENARIO-007 — Enterprise Integration Onboarding and Inventory-Truth Matching |
| [seq-008.md](seq-008.md) | SCENARIO-008 — Zero-Knowledge Dispute Mediation and Settlement Adjustment |
| [seq-009.md](seq-009.md) | SCENARIO-009 — Aggregate Insight Publication and the Demand-Planning Loop |
| [seq-010.md](seq-010.md) | SCENARIO-010 — Independent Certification of the Full Evidence Trail |

## How they relate

- Doc 1 names the blocks and places them on the lab network; docs 2–9 open one application each.
- Foundation services (`fabric-coordinator`, `slice-runtime`, `identity-mock`, `ledger-svc`) appear as external boxes in every application diagram — they are defined in [../design.md](../design.md) §4 and drawn open in doc 1.
- Scenario coverage per application is listed at the bottom of each document, tracing back to [../scenarios.md](../scenarios.md).
- The seq-\* documents show docs 2–9's components exchanging messages in scenario order: each opens with a Note stating seeded preconditions and closes with a Note stating the Target Verification Point Yuruna asserts.
