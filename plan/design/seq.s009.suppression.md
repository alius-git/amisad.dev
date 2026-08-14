# s009.suppression sequence — Aggregate Insight Publication and the Demand-Planning Loop

> One sentence: sealed environments emit only aggregates, the threshold gate suppresses the small region into indistinguishable absence, and one published outlook drives both stocking and campaign decisions.

See [../design.md](../design.md#9-diagrams) · [s009.suppression](../scenarios.md#s009suppression-aggregate-insight-publication-and-the-demand-planning-loop).

```mermaid
sequenceDiagram
    participant RegionA as Match activity · region A (above threshold)
    participant RegionB as Match activity · region B (below threshold)
    participant InsightsSvc as insights-svc
    actor Dana
    participant SellerSvc as seller-svc
    actor Elena
    participant AdsSvc as ads-svc
    actor Marcel

    Note over RegionA,Marcel: Seeded - match activity places region A above and region B below the anonymity threshold in one category. This scenario runs entirely on vm-core; the contributions arrive as recorded per-cell counts, never as content
    RegionA->>InsightsSvc: Aggregate contributions - category, region, window
    RegionB->>InsightsSvc: Aggregate contributions
    InsightsSvc->>InsightsSvc: Threshold gate - below-floor cells suppressed, not zeroed
    Dana->>InsightsSvc: Open insights workbench
    InsightsSvc-->>Dana: Region A shows rising demand - region B entirely absent
    Dana->>InsightsSvc: Publish demand outlook - versioned and immutable
    Elena->>SellerSvc: Open the demand-outlook view for that version
    SellerSvc->>InsightsSvc: Read the published version straight through
    InsightsSvc-->>Elena: Published figures
    Marcel->>AdsSvc: Open the demand view for the same version
    AdsSvc->>InsightsSvc: Read the published version straight through
    InsightsSvc-->>Marcel: Identical figures by construction
    Note over SellerSvc,AdsSvc: Stocking and campaign decisions rest on one version, not two reports
    Dana->>InsightsSvc: Review ecosystem health
    InsightsSvc-->>Dana: Unmet-demand flag - category and region only
    Note over InsightsSvc,Marcel: Yuruna queries every published view - no figure derived from region B exists anywhere downstream
    Note over RegionA,Marcel: Yuruna asserts - every published aggregate satisfies the threshold, outlook figures identical across consumers, no query path returns individual-level or below-threshold data
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
