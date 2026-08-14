# s007.inventory sequence — Enterprise Integration Onboarding and Inventory-Truth Matching

> One sentence: a verified connector certifies in sandbox, syncs ERP truth into matching, mirrors order states back out, and is refused beyond its scope — with replay converging and revocation killing credentials, not data.

See [../design.md](../design.md#9-diagrams) · [s007.inventory](../scenarios.md#s007inventory-enterprise-integration-onboarding-and-inventory-truth-matching). ledger-svc is folded into seller-svc's settlement step; the matching fabric is folded into the coordinator.

```mermaid
sequenceDiagram
    actor Alex
    actor Priya
    actor Elena
    participant ERP as ERP connector (played by the scenario)
    participant ConnectSvc as connect-svc
    participant SellerSvc as seller-svc
    participant Coordinator as fabric-coordinator

    Note over Alex,Coordinator: Seeded - Elena's ERP catalog with one item at a single unit of stock
    Alex->>ConnectSvc: Register as integration partner
    ConnectSvc-->>Alex: Registered - sandbox access only
    Alex->>ConnectSvc: Certify the connector against the same contracts
    Note over ConnectSvc,Priya: Promotion beyond sandbox belongs to Priya's participant registry - not built in the POC, so sandbox and certification are tracked in connect-svc
    Elena->>ConnectSvc: Grant scoped access - catalog, inventory, orders
    ConnectSvc-->>ERP: Credential capped to exactly that scope
    ERP->>ConnectSvc: Sync catalog into Elena's tenant
    ConnectSvc->>SellerSvc: Offers matchable
    Note over ERP: Counter sale in the shop - last unit of the item sells externally
    ERP->>ConnectSvc: Inventory delta
    ConnectSvc->>SellerSvc: Stock zero - the item leaves the matchable catalog
    Coordinator->>SellerSvc: Fetch offers for the seeded buyer need
    SellerSvc-->>Coordinator: Only the in-stock alternative, though the zeroed item was cheaper
    SellerSvc->>ConnectSvc: Order state transitions, one detached notify each
    ConnectSvc-->>ERP: Mirrored under an idempotency key, advancing monotonically
    alt out-of-scope call
        ERP->>ConnectSvc: Request beyond granted scope
        ConnectSvc-->>ERP: Refused on credential scope - attempt logged, nothing returned
    end
    Note over ConnectSvc,ERP: Yuruna replays a delivery - the mirror converges, no duplicate effects
    Elena->>ConnectSvc: Revoke the integration grant
    ERP->>ConnectSvc: Next sync attempt
    ConnectSvc-->>ERP: Credential invalid - Elena's catalog intact and hand-editable
    Note over Alex,Coordinator: Yuruna asserts - no match references externally zeroed inventory, ERP and seller order states identical at every transition, out-of-scope refused and logged, replay idempotent, zero buyer data in any integration payload or log
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
