# s001.fulfillment sequence — Intent-Driven Edge Match and Automated Fulfillment

> One sentence: a private need auto-closes against a standing offer inside a sealed edge environment and settles across all four parties — the golden path.

See [../design.md](../design.md#9-diagrams) · [s001.fulfillment](../scenarios.md#s001fulfillment-intent-driven-edge-match-and-automated-fulfillment). Tom is folded into resource-svc (the carrier share he would read is a party in the recorded split).

```mermaid
sequenceDiagram
    actor Maya
    participant BuyerApp as Buyer client
    participant Coordinator as fabric-coordinator
    participant ResourceSvc as resource-svc
    participant SellerSvc as seller-svc
    participant SliceRT as slice-runtime
    participant LedgerSvc as ledger-svc
    actor Elena

    Note over Maya,Elena: Seeded - Maya verified with active consent, Elena holds an auto-close standing deal
    Maya->>BuyerApp: State need - gift, budget cap, city, deadline, auto-close policy
    BuyerApp->>Coordinator: Sealed need envelope
    Coordinator->>ResourceSvc: Placement request for buyer jurisdiction
    ResourceSvc-->>Coordinator: Compliant slice allocation
    Coordinator->>SellerSvc: Fetch the jurisdiction's catalog
    SellerSvc-->>Coordinator: Candidate offers
    Coordinator->>SliceRT: Create attested environment - envelope and offers travel in
    SliceRT->>SliceRT: Match computed - both auto-close policies permit
    SliceRT->>LedgerSvc: Attestation lifecycle + settlement instruction
    SliceRT->>ResourceSvc: Lifecycle telemetry
    SliceRT-->>Coordinator: Match record - environment destroyed on completion
    Coordinator->>SellerSvc: Committed order - need context, no buyer identity
    Coordinator-->>BuyerApp: Match result with pseudonymous order handle
    Elena->>SellerSvc: Ship - order advances through provisioning to fulfilled
    SellerSvc->>LedgerSvc: Fulfillment confirmed - four-way split recorded, order settles
    BuyerApp->>Coordinator: Poll order status on the handle
    Coordinator-->>BuyerApp: Delivered - read through from the seller order, pseudonymous
    Note over Maya,Elena: Yuruna asserts - one settlement record summing to match value, Delivered/Settled states share one match ID, attestation chain complete, zero need or identity egress, and the ledger and order rows survive a pod restart
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
