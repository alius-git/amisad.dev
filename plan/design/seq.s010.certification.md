# s010.certification sequence — Independent Certification of the Full Evidence Trail

> One sentence: the auditor recomputes chains, residency, consent, and settlement conservation over a corpus spanning every kind of evidence s001–s009 produce, catches an injected tamper by recomputation, and certifies on evidence — read-only throughout.

See [../design.md](../design.md#9-diagrams) · [s010.certification](../scenarios.md#s010certification-independent-certification-of-the-full-evidence-trail).

```mermaid
sequenceDiagram
    actor Ingrid
    participant AuditSvc as audit-svc
    participant LedgerSvc as ledger-svc
    participant PlatformSvc as platform-svc
    actor Priya

    Note over Ingrid,Priya: Seeded - the scenario builds its own corpus, one instance of every kind of evidence s001 through s009 produce: a completed match plus an injected abort, consent granted and revoked, a mandate, a disclosure and its adjustment
    Ingrid->>AuditSvc: Start certification run
    AuditSvc->>LedgerSvc: Read every record on all three chains - read endpoints only
    AuditSvc->>AuditSvc: Recompute the chains from the raw records - trusting no ledger self-report
    AuditSvc->>AuditSvc: Verify attestation continuity - every environment created-attested-executed or aborted-destroyed
    AuditSvc->>AuditSvc: Verify residency - the attested region satisfies the jurisdiction
    AuditSvc->>AuditSvc: Verify consent - the chain is intact across all four grant types
    AuditSvc->>AuditSvc: Verify settlement conservation - splits sum, adjustments compensate and reference cases
    alt tamper check
        Ingrid->>AuditSvc: Submit a copy of the attestation records with one row modified
        AuditSvc-->>Ingrid: Recomputation localizes the tamper to exactly that record
    end
    AuditSvc-->>Ingrid: Findings per dimension - violation counts and the overall verdict
    Ingrid->>PlatformSvc: Deliver the findings to operations
    PlatformSvc->>Priya: Findings received in operations
    Note over AuditSvc: Own access log - exclusively read operations, no personal-data scope ever exercised
    Note over Ingrid,Priya: Yuruna asserts - all four dimensions report zero unexplained violations, the tamper is detected and localized, and the audit access log proves read-only isolation
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
