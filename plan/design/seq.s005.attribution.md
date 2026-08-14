# s005.attribution sequence — Campaign-Boosted Match, Edge Creative Serving, and Attribution Credit

> One sentence: brief becomes creative, creative rides into the sealed environment with the qualified offer, and closing yields agency and creator credit computed in the fabric — attribution without tracking.

See [../design.md](../design.md#9-diagrams) · [s005.attribution](../scenarios.md#s005attribution-campaign-boosted-match-edge-creative-serving-and-attribution-credit). Maya is folded into the buyer app; Elena's offer arrives via the coordinator's seller-svc fetch.

```mermaid
sequenceDiagram
    actor Marcel
    actor Kai
    participant AdsSvc as ads-svc
    participant InsightsSvc as insights-svc
    participant BuyerApp as Buyer app (Maya)
    participant Coordinator as fabric-coordinator
    participant SliceRT as slice-runtime
    participant LedgerSvc as ledger-svc

    Note over Marcel,LedgerSvc: Seeded - Elena's summer collection live in seller-svc, aggregate demand published for the target region
    InsightsSvc-->>AdsSvc: Published outlook - where demand lives
    Marcel->>AdsSvc: Create campaign - region, need category, budget, per-match commitment
    Marcel->>AdsSvc: Issue creative brief
    AdsSvc->>Kai: Brief appears in demand queue
    Kai->>AdsSvc: Produce asset - approved creative
    Marcel->>AdsSvc: Place approved asset - campaign active, pacing begins
    BuyerApp->>Coordinator: Need envelope in campaign category and region, manual closing
    Coordinator->>AdsSvc: Fetch the region's active campaigns
    Coordinator->>SliceRT: Environment - envelope, offers, and campaigns travel in
    SliceRT->>SliceRT: Campaign qualifies the offer - creative rendered inside the environment, logged on ingress
    SliceRT-->>Coordinator: Shortlist - the offer carries the creative
    Coordinator-->>BuyerApp: Shortlist delivered
    BuyerApp->>Coordinator: Accept - the boosted match closes
    Coordinator->>LedgerSvc: Five-way split - seller, network, platform funded by the price; agency and creator by the commitment on top
    Coordinator->>AdsSvc: Credit assignment - campaign, asset, opaque match id
    AdsSvc->>AdsSvc: Budget decrements by the per-match commitment, not impressions
    Note over Marcel,LedgerSvc: Yuruna asserts - settlement includes non-zero ad-partner credit referencing campaign and asset IDs, dashboards match the ledger, creative in the ingress log, zero buyer signal campaign-side, decrement equals per-match commitment, seller revenue unchanged by the boost
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
