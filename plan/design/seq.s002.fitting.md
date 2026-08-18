# s002.fitting sequence — Considered Purchase, Constraint Fidelity, and In-Person Booking

> One sentence: a constraint-rich need returns a shortlist that honors every constraint including exclusions, nothing commits until the buyer decides, and a one-tap booking reaches the seller without her identity.

See [../design.md](../design.md#9-diagrams) - [s002.fitting](../scenarios.md#s002fitting-considered-purchase-constraint-fidelity-and-in-person-booking).

```mermaid
sequenceDiagram
    actor Maya
    participant BuyerApp as Buyer client
    participant Coordinator as fabric-coordinator
    participant SellerSvc as seller-svc
    participant SliceRT as slice-runtime
    participant LedgerSvc as ledger-svc
    actor Elena

    Note over Maya,Elena: Seeded - Elena's catalog includes a dusty blue dress and a Thursday slot, a second seller is out of range or past deadline
    Maya->>BuyerApp: State need - midi, sleeves, warm fabric, NOT dusty blue, fitting before Friday, manual closing
    BuyerApp->>Coordinator: Sealed need envelope
    Coordinator->>SellerSvc: Fetch the jurisdiction's catalog
    SellerSvc-->>Coordinator: Candidate offers
    Coordinator->>SliceRT: Create attested environment - envelope and offers travel in
    SliceRT->>SliceRT: Evaluate every constraint including exclusions
    SliceRT-->>Coordinator: Shortlist - only fully fitting offers, no match id
    Coordinator-->>BuyerApp: Shortlist delivered (notification 1)
    Note over Coordinator,SellerSvc: Manual policy - zero commitments exist at this point
    Maya->>BuyerApp: Select one dress, book the Thursday fitting
    BuyerApp->>Coordinator: Accept offer and book slot
    Coordinator->>LedgerSvc: Settlement instruction for the booked match
    Coordinator->>SellerSvc: Committed order - dress requirements and slot, no buyer identity
    Coordinator-->>BuyerApp: Booking confirmed (notification 2)
    Elena->>SellerSvc: Fitting appointment on the order board, fulfilled and closed
    SellerSvc->>LedgerSvc: Fulfillment confirmed - split recorded, order settles
    Note over Maya,Elena: Yuruna asserts - dusty blue and out-of-range offers absent from shortlist, no pre-decision commitment, appointment records consistent and identity-free, notification count is exactly two
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
