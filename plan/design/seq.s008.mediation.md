# s008.mediation sequence — Zero-Knowledge Dispute Mediation and Settlement Adjustment

> One sentence: a delivery dispute resolves on metadata plus one minimal, time-boxed, consented disclosure, the refund lands as compensating entries referencing the case — and the buyer stays anonymous throughout.

See [../design.md](../design.md#9-diagrams) · [s008.mediation](../scenarios.md#s008mediation-zero-knowledge-dispute-mediation-and-settlement-adjustment).

```mermaid
sequenceDiagram
    actor Maya
    participant BuyerApp as Buyer client
    participant PlatformSvc as platform-svc (support desk)
    actor Sam
    participant Coordinator as fabric-coordinator
    participant LedgerSvc as ledger-svc
    actor Priya

    Note over Maya,Priya: Seeded - a settled order (s001.fulfillment style) whose delivery confirmation conflicts with reality
    Maya->>BuyerApp: Report non-delivery
    BuyerApp->>PlatformSvc: Case opens - order state and settlement metadata only, no identity
    PlatformSvc->>Sam: Case in support queue
    Sam->>PlatformSvc: Review - carrier confirmation conflicts with the report
    alt metadata cannot resolve the case
        Sam->>PlatformSvc: Request consented disclosure - minimal scope, time-boxed
        Maya->>BuyerApp: Grant
        BuyerApp->>Coordinator: Disclosure grant for this case, with its time box
        Coordinator->>LedgerSvc: Grant recorded under her pseudonymous subject
        Coordinator->>PlatformSvc: Exactly the granted artifact, carrying its expiry
        PlatformSvc-->>Sam: Artifact read-only - identity still withheld
    end
    Sam->>LedgerSvc: Evidence supports the buyer - refund posts as compensating entries referencing the case
    Note over LedgerSvc: History is never edited - the chains still verify and the derived net reflects the refund
    Sam->>PlatformSvc: Resolution recorded, case closed
    Sam->>PlatformSvc: Recurring pattern escalated to operations
    PlatformSvc->>Priya: Cross-party case in the operations queue
    Note over PlatformSvc: Disclosure grant expires - the artifact path is gone
    Note over Maya,Priya: Yuruna asserts - case record identity-free end to end, grant history reads request-grant-delivery-expiry with scope never exceeded, adjustment exists only as case-referencing compensating entries, post-expiry access fails
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
