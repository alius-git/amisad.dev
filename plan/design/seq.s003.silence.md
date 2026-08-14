# s003.silence sequence — Consent Revocation and the Right to Silence

> One sentence: pausing participation stops matching at the consent check itself, committed orders still complete, withdrawal ends aggregate contribution, and resumption restores service — all immutably recorded.

See [../design.md](../design.md#9-diagrams) · [s003.silence](../scenarios.md#s003silence-consent-revocation-and-the-right-to-silence).

```mermaid
sequenceDiagram
    actor Maya
    participant BuyerApp as Buyer client
    participant Coordinator as fabric-coordinator
    participant LedgerSvc as ledger-svc
    participant SellerSvc as seller-svc
    participant InsightsSvc as insights-svc
    actor Elena

    Note over Maya,Elena: Seeded - one committed order in flight, two needs open on the coordinator and still matching
    Maya->>BuyerApp: Pause participation
    BuyerApp->>Coordinator: Revoke participation
    Coordinator->>LedgerSvc: Revocation appended under her pseudonymous subject
    Elena->>SellerSvc: Publish new offer that would perfectly fit an open need
    SellerSvc->>Coordinator: Offer-published event - re-run the open needs
    Coordinator->>LedgerSvc: Consent check for this matching cycle
    LedgerSvc-->>Coordinator: Revoked - no environment created for her needs
    Note over Coordinator,Elena: Silence - no match, no notification, nothing happens
    Elena->>SellerSvc: Fulfill the in-flight order
    SellerSvc->>LedgerSvc: Pre-revocation commitment settles normally
    BuyerApp->>Coordinator: Poll order status on the handle
    Coordinator-->>BuyerApp: Delivered - pseudonymous, unaffected by the revocation
    Maya->>BuyerApp: Withdraw entirely
    BuyerApp->>Coordinator: Revoke aggregate contribution
    Coordinator->>LedgerSvc: Second revocation recorded
    InsightsSvc->>Coordinator: Aggregation cycle - count of contributing open needs
    Coordinator-->>InsightsSvc: Nothing of hers counted
    Maya->>BuyerApp: Resume participation
    BuyerApp->>Coordinator: Re-grant contribution and participation
    Coordinator->>LedgerSvc: New grants recorded
    Coordinator->>Coordinator: Open needs immediately re-served
    Note over Maya,Elena: Yuruna asserts - zero match events and zero environments for this buyer between revocation and resumption, in-flight order reaches Settled, full grant-revoke-regrant history immutable on the verifying consent chain and in PostgreSQL, zero notifications in the paused window
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
