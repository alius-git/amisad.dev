# AmisAd POC — Master Design

**Companion documents:** [personas.md](personas.md) · [applications.md](applications.md) · [scenarios.md](scenarios.md) · diagrams under [design/](design/), indexed in [§9](#9-diagrams)

> One sentence: how the eight AmisAd applications and four shared foundations become a proof-of-concept that runs in local VMs and side-loaded test devices, executes all ten verification scenarios under Yuruna, and grows into the full cloud-hosted and mobile ecosystem without contract changes.

---

## 1. Decisions locked

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Backend language | **Rust** (one Cargo workspace; Actix Web, matching the Ordem codebase) | One stack for all services and the slice runtime; tiny static binaries fit the light-slice principle |
| Mobile app | **Flutter** (Android side-loaded for POC; iOS on the growth path) | One codebase for both platforms later; offline-first with an encrypted local vault |
| Web UIs | **One shared SPA** — React + TypeScript + Vite, one app shell with role-scoped modules | Seven UIs, one frontend toolchain; served as static assets from the cluster |
| Code location | **`amisad.dev/poc/`** | POC status explicit; planning docs and code in one repo |
| Kubernetes | **k3s**, single-node cluster in one VM | Lightest conformant K8s; nothing cloud-specific; Traefik ingress included |
| Database | **PostgreSQL** (one in-cluster instance, schema per service) | Sole database per principles; ledgers as append-only hash-chained tables |
| Events | **NATS JetStream** (in-cluster) | One lightweight broker; persistent streams give the idempotent replay SCENARIO-007 asserts |
| Identity | **identity-mock**, a Rust OIDC-style JWT issuer | In-stack mock of Identity & Verification; four actor classes; swappable for carrier federation |
| API style | Versioned REST/JSON under `/v1`, OpenAPI-documented, contracts checked in under `poc/contracts/` | Per principles; the contract files are the compatibility gate |

## 2. POC topology

Four machines, all provisioned and driven by Yuruna (see [design/01-overview.md](design/01-overview.md) for the diagrams):

| Node | Role |
|------|------|
| **Dev host** | Yuruna test runner, status service, VM provisioning (Hyper-V/KVM/UTM — any supported host) |
| **vm-core** | k3s cluster: the seven server-side application services, foundation services, PostgreSQL, NATS, SPA static serving |
| **vm-edge-a**, **vm-edge-b** | Two "slice VMs" — the telco-local edge, one per simulated region/jurisdiction |
| **Test mobile device** | Flutter buyer app, side-loaded, reaching vm-core over the lab LAN |

Two edge VMs are the minimum honest topology: SCENARIO-004 requires a jurisdiction-restricted allocation choosing between regions, and SCENARIO-009 requires one region above and one below the anonymity threshold.

**Slice VMs stay stateless.** Each runs only the `slice-runtime` binary: it accepts an allocation from the fabric coordinator, spawns an **ephemeral match environment** (one process per match, simulated enclave), reports its attestation lifecycle, emits the match record, and dies. No database, no persistent volume, no queue on the edge; a rebooted slice VM is indistinguishable from a fresh one.

## 3. Application inventory

Every application from [applications.md](applications.md) exists in the POC — SCENARIO-001…010 assert against all of them, and the principles forbid stubbing anything a scenario asserts against.

| Application | POC realization | UI |
|-------------|-----------------|----|
| AmisAd/buyer | Flutter app: encrypted on-device vault, needs list, closing-policy engine, delegate mode, consent/mandate controls | Mobile (side-loaded) |
| AmisAd/seller | `seller-svc`: catalog, inventory, order state machine, settlement view, integration grants | SPA module |
| AmisAd/resource | `resource-svc`: allocation policy, slice controller (drives edge VMs), telemetry, incidents, carrier settlement report | SPA module |
| AmisAd/ads | `ads-svc`: campaign + creative-studio modes, asset store, budget pacing, attribution reports | SPA module |
| AmisAd/insights | `insights-svc`: threshold-enforcing aggregation pipeline, workbench, outlook publisher | SPA module |
| AmisAd/platform | `platform-svc`: operations + support-desk modes, participant registry, anomaly detection, adjustment proposals | SPA module |
| AmisAd/audit | `audit-svc`: chain verifier, certification runner, investigation views — read-only by construction | SPA module |
| AmisAd/connect | `connect-svc`: versioned contracts, sandbox tenants, workload credentials, webhook dispatch (JetStream) | SPA module |

The buyer application deliberately has **no dedicated backend service**: the vault lives on the device, and the app talks only to the fabric coordinator (need envelopes, match results), `ledger-svc` (consent, mandates), and pseudonymous order-status subjects on NATS — so there is no server-side store of buyer needs to protect, in the POC or ever.

## 4. Foundations realization

- **Private Matching Fabric** = `fabric-coordinator` (in-cluster) + `slice-runtime` (edge VMs). The buyer app encrypts the need as an **envelope keyed to the ephemeral environment**; the coordinator picks a slice per jurisdiction policy (from `resource-svc`) and routes the envelope; only the environment can open it. Core services never hold plaintext needs. Offers, campaign creative, and mandates travel in; the match record, settlement instruction, and threshold-protected aggregate contributions travel out; the environment's `created → attested → executed/aborted → destroyed` lifecycle is written to the attestation ledger.
- **Identity & Verification** = `identity-mock`: issues short-lived JWTs for the four actor classes (person, organization, delegate-bound-to-principal, workload) and backs the platform participant registry. Production replaces the issuer, not the token contract.
- **Consent Ledger + Settlement & Attribution Ledger + attestation log** = `ledger-svc`: three append-only, hash-chained PostgreSQL table families behind one Rust service. Writes are inserts only; balances and views are derived; disputes land as compensating entries referencing their case; chain heads are exposed for `audit-svc` to verify independently. No blockchain.
- **Event backbone** = NATS JetStream subjects per domain (`orders.*`, `inventory.*`, `campaigns.*`, `cases.*`), consumed idempotently; `connect-svc` webhook delivery and replay ride the same streams.

## 5. Mock boundary

Every mock implements the production interface; swapping it changes no caller.

| Production capability | POC stand-in | Preserved contract |
|-----------------------|--------------|--------------------|
| TEE / confidential computing | `slice-runtime` process isolation + **attestation simulator** | Attestation record schema, lifecycle states, chain format |
| Carrier network slices | Edge VMs; `resource-svc` slice controller starts/stops match runtimes | Allocation API, jurisdiction constraint evaluation, telemetry stream |
| SIM-anchored identity | `identity-mock` JWT issuer | Token claims, actor classes, verification states |
| Payments | Settlement-ledger entries only; no money moves | Split computation, compensating-entry adjustments |
| On-device matching | Always matched on edge slices in POC | Envelope encryption; the vault never syncs server-side |
| Creative production tooling | File upload into the `ads-svc` asset store | Brief → draft → approved → placed lifecycle, environment ingress |

## 6. Repository layout

The POC mirrors the **yuruna-project convention** (components / config /
workloads / test) so the Yuruna runner discovers and drives it, with **Bazel**
(pinned via bazelisk) as the single build entry point:

```
amisad.dev/
  plan/                     # planning docs (this file, personas, applications, scenarios, design/)
  poc/
    MODULE.bazel            # Bazel root (bzlmod, rules_rust pinned; .bazelversion via bazelisk)
    build/                  # doctor.ps1 (toolchain check), build-all.ps1, images.ps1, serve-local.ps1
    contracts/              # OpenAPI specs + NATS event schemas — the compatibility gate
    components/
      services/             # 10 Rust services (seller-svc … ledger-svc)
      edge/slice-runtime/   # stateless edge match runtime (Rust, same workspace)
      apps/buyer-client/    # headless buyer (Rust CLI) driving the scenario sequences
      apps/buyer-flutter/   # Flutter buyer app (Android side-loaded)
      apps/web-spa/         # React+TS+Vite shell with role-scoped modules
      lib/amisad-common/    # shared config/health plumbing crate
      art/                  # canonical brand assets + palette tokens (from amisad.com)
    config/localhost/       # three-phase deploy config (resources → components → workloads)
    workloads/services/     # minimal Helm chart per service
    db/                     # schema.sql (hash-chained ledgers) + per-scenario seeds
    test/gui/               # Yuruna sequences: baseline snapshot + SCENARIO-001…010
    test/ubuntu.server.24/  # guest scripts the sequences fetch-and-execute
```

## 7. Scenario execution

Yuruna provisions the four nodes, deploys via `poc/config/localhost/`, seeds from `poc/db/seed/`, and executes [scenarios.md](scenarios.md) as its discovered sequences — SCENARIO-001…009 in priority order, then SCENARIO-010 certifying the evidence corpus they produced. Each scenario's Target Verification Point maps to asserts against observable state: ledger sums and chain heads via `ledger-svc`/`audit-svc` APIs, environment lifecycles via the attestation ledger, application state via the `/v1` APIs, and the slice VMs' egress logs for the zero-leak assertions.

## 8. Growth path

| POC | Full system |
|-----|-------------|
| Single-node k3s in one VM | Conformant managed or self-run K8s on any cloud — the no-managed-services rule keeps the manifests portable |
| Two edge VMs | Carrier MEC sites with hardware TEEs — attestation simulator swapped for real quotes, same schema |
| `identity-mock` | Carrier identity federation behind the same token contract |
| One PostgreSQL instance | Per-service clusters; ledger schemas unchanged |
| Side-loaded Android build | Store-distributed Android + iOS from the same Flutter codebase |
| SPA served from the cluster | Same build behind a CDN |
| Yuruna lab sequences | The same sequences as staging/production conformance gates |

## 9. Diagrams

The documents under [design/](design/) visualize this design, they do not restate it. Every diagram holds at most seven boxes; planned/growth-path items use dashed edges.

| # | Document | Diagram type | Shows |
|---|----------|--------------|-------|
| 1 | [POC overview](design/01-overview.md) | flowchart ×2 | The seven top-level POC blocks; the four-node deployment topology. |
| 2 | [AmisAd/buyer](design/02-buyer.md) | flowchart | Flutter app internals: vault, matching path, delegate mode. |
| 3 | [AmisAd/seller](design/03-seller.md) | flowchart | seller-svc: catalog, inventory, order state machine, grants. |
| 4 | [AmisAd/resource](design/04-resource.md) | flowchart | resource-svc: policy, slice controller, telemetry, incidents. |
| 5 | [AmisAd/ads](design/05-ads.md) | flowchart | ads-svc: campaign + studio modes, assets, attribution. |
| 6 | [AmisAd/insights](design/06-insights.md) | flowchart | insights-svc: threshold pipeline, workbench, outlooks. |
| 7 | [AmisAd/platform](design/07-platform.md) | flowchart | platform-svc: operations + support desk, registry, adjustments. |
| 8 | [AmisAd/audit](design/08-audit.md) | flowchart | audit-svc: chain verification, certification, reporting. |
| 9 | [AmisAd/connect](design/09-connect.md) | flowchart | connect-svc: contracts, sandbox, credentials, webhooks. |

One sequence diagram per verification scenario, faithful to the numbered steps in [scenarios.md](scenarios.md); participants are the POC components above, personas as actors, at most 8 lifelines each. Each traces its scenario's steps through the POC components to its Target Verification Point.

| Document | Sequence for |
|----------|--------------|
| [seq-001.md](design/seq-001.md) | SCENARIO-001 — Intent-Driven Edge Match and Automated Fulfillment |
| [seq-002.md](design/seq-002.md) | SCENARIO-002 — Considered Purchase, Constraint Fidelity, and In-Person Booking |
| [seq-003.md](design/seq-003.md) | SCENARIO-003 — Consent Revocation and the Right to Silence |
| [seq-004.md](design/seq-004.md) | SCENARIO-004 — Sovereign Slice Allocation, Isolation Fault, and Attested Failover |
| [seq-005.md](design/seq-005.md) | SCENARIO-005 — Campaign-Boosted Match, Edge Creative Serving, and Attribution Credit |
| [seq-006.md](design/seq-006.md) | SCENARIO-006 — Delegated Procurement Under a Scoped Mandate |
| [seq-007.md](design/seq-007.md) | SCENARIO-007 — Enterprise Integration Onboarding and Inventory-Truth Matching |
| [seq-008.md](design/seq-008.md) | SCENARIO-008 — Zero-Knowledge Dispute Mediation and Settlement Adjustment |
| [seq-009.md](design/seq-009.md) | SCENARIO-009 — Aggregate Insight Publication and the Demand-Planning Loop |
| [seq-010.md](design/seq-010.md) | SCENARIO-010 — Independent Certification of the Full Evidence Trail |

How the documents relate:

- Doc 1 names the blocks and places them on the lab network; docs 2–9 open one application each.
- Foundation services (`fabric-coordinator`, `slice-runtime`, `identity-mock`, `ledger-svc`) appear as external boxes in every application diagram — they are defined in §4 above and drawn open in doc 1.
- Scenario coverage per application is listed at the bottom of each document, tracing back to [scenarios.md](scenarios.md).
- The seq-\* documents show docs 2–9's components exchanging messages in scenario order: each opens with a Note stating seeded preconditions and closes with a Note stating the Target Verification Point Yuruna asserts.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
