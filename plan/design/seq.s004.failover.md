# s004.failover sequence — Sovereign Slice Allocation, Isolation Fault, and Attested Failover

> One sentence: jurisdiction rules pick the compliant region over the roomier one, an injected isolation fault destroys the environment safely and retries clean, and the systemic pattern escalates across party lines.

See [../design.md](../design.md#9-diagrams) - [s004.failover](../scenarios.md#s004failover-sovereign-slice-allocation-isolation-fault-and-attested-failover). slice-runtime B is folded into resource-svc (it is the roomier registered edge the policy excludes, and it exchanges no messages).

```mermaid
sequenceDiagram
    actor Tom
    participant ResourceSvc as resource-svc
    participant Coordinator as fabric-coordinator
    participant SliceA as slice-runtime A (compliant)
    participant LedgerSvc as ledger-svc
    participant PlatformSvc as platform-svc
    actor Priya

    Note over Tom,Priya: Seeded - two regions with capacity, buyer needs carry a jurisdiction restriction satisfied only by region A, and Yuruna has armed two consecutive isolation faults
    Tom->>ResourceSvc: Configure allocation policy - regions, capacity, jurisdiction constraint
    Coordinator->>ResourceSvc: Placement request for restricted-jurisdiction buyer
    Note over ResourceSvc: slice-runtime B has more free capacity - excluded by jurisdiction constraint at allocation time
    ResourceSvc-->>Coordinator: Allocate region A only
    loop each armed fault
        Coordinator->>SliceA: Create attested environment
        SliceA->>SliceA: Self-terminate right after attestation, BEFORE the envelope is opened
        SliceA->>LedgerSvc: created-attested-aborted-destroyed with the fault reason - no match record
        SliceA->>ResourceSvc: Abort telemetry
        ResourceSvc->>Tom: Incident raised in queue
        SliceA-->>Coordinator: Aborted - isolation fault
    end
    Coordinator->>SliceA: Automatic retry - fresh environment, same compliant placement
    SliceA->>SliceA: Match completes
    SliceA->>LedgerSvc: Attestation lifecycle + settlement instruction
    Note over Tom,Priya: Two aborts in a row - the pattern is systemic
    Tom->>PlatformSvc: Escalate cross-party incident, linking both environment ids
    PlatformSvc->>Priya: Case opened, referencing both aborted lifecycles
    Note over LedgerSvc: seller-svc fulfillment confirms the retry's split
    LedgerSvc-->>Tom: Exactly one settlement - the aborted environments earned nothing
    Note over Tom,Priya: Yuruna asserts - zero out-of-region attestation entries and the roomier region positively excluded, aborted lifecycle reads created-attested-aborted-destroyed with nothing need-derived in it, exactly one settlement record, incident case references both environment lifecycles
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.

[Design](../design.md) | [Design overview](README.md)
