# s006.mandate sequence — Delegated Procurement Under a Scoped Mandate

> One sentence: a mandate grants Pat bounded authority that the fabric enforces at match time -- in-scope closes with dual attribution, over-cap routes to Maya, out-of-scope never reaches matching, and revocation is instant.

See [../design.md](../design.md#9-diagrams) - [s006.mandate](../scenarios.md#s006mandate-delegated-procurement-under-a-scoped-mandate). Elena's standing offer is folded into the coordinator's offer fetch.

```mermaid
sequenceDiagram
    actor Maya
    actor Pat
    participant BuyerApp as Buyer app
    participant IdentityMock as identity-mock
    participant LedgerSvc as ledger-svc
    participant Coordinator as fabric-coordinator
    participant SliceRT as slice-runtime

    Note over Maya,SliceRT: Seeded - household-goods category, per-item closing limit, expiry
    Maya->>BuyerApp: Grant mandate to Pat
    BuyerApp->>Coordinator: Mandate - delegate, category, per-item cap, expiry
    Coordinator->>LedgerSvc: Mandate recorded as a consent grant type
    Note over Coordinator: Scope lives here; the immutable grant history lives on the chain
    Pat->>BuyerApp: Open delegate workspace
    BuyerApp->>IdentityMock: Pat's actor token
    BuyerApp->>Coordinator: Workspace request
    Coordinator-->>BuyerApp: Maya as principal, with the mandate's scope
    Pat->>BuyerApp: State in-scope need under the per-item limit
    BuyerApp->>Coordinator: Delegated need - principal named, envelope sealed
    Coordinator->>Coordinator: Mandate scope checked BEFORE any dispatch
    Coordinator->>SliceRT: Environment - envelope and offers travel in
    SliceRT-->>Coordinator: Match within the cap
    Coordinator->>LedgerSvc: Settlement instruction - closing on Pat's authority
    Coordinator->>Coordinator: Dual attribution on Maya's activity trail (actor Pat, principal Maya, mandate)
    BuyerApp-->>Maya: Activity trail shows the delegated action
    Pat->>BuyerApp: State second need - best match exceeds the per-item limit
    alt closing beyond delegated authority
        Coordinator->>Coordinator: Match HELD - offer chosen, nothing committed
        Coordinator-->>Maya: Approval handoff
        Maya->>BuyerApp: Approve
        BuyerApp->>Coordinator: Closing completes - attributed via principal approval
    end
    alt out-of-scope category
        Pat->>BuyerApp: Attempt need outside the mandated category
        Coordinator-->>Pat: Refused at submission - zero environments, zero entries
    end
    Maya->>BuyerApp: Revoke mandate
    BuyerApp->>Coordinator: Revocation - delegate workspace cleared immediately
    Coordinator->>LedgerSvc: Revocation recorded on the consent chain
    alt delegated attempt after revocation
        Pat->>BuyerApp: Attempt delegated action
        Coordinator-->>Pat: Mandate check fails
    end
    Note over Maya,SliceRT: Yuruna asserts - every delegated match carries dual attribution to a then-valid mandate, over-cap closing exists only after recorded approval, out-of-scope attempt produced zero environments and entries, nothing delegated exists after revocation
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
