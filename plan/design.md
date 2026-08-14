# AmisAd POC — Master Design

**Companion documents:** [personas.md](personas.md) · [applications.md](applications.md) · [scenarios.md](scenarios.md) · diagrams under [design/](design/), indexed in [§9](#9-diagrams)

> One sentence: how the eight AmisAd applications and four shared foundations become a proof-of-concept that runs in local VMs and side-loaded test devices, executes all ten verification scenarios under Yuruna, and grows into the full cloud-hosted and mobile ecosystem without contract changes.

---

## 1. Decisions locked

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Backend language | **Rust** (one Cargo workspace; Actix Web, matching the Ordem codebase) | One stack for all services and the slice runtime; tiny static binaries fit the light-slice principle |
| Mobile app | **Flutter** (Android side-loaded for POC; iOS on the growth path) | One codebase for both platforms later; offline-first with an encrypted local vault |
| Web UIs | **One shared SPA** — React + TypeScript + Vite, one app shell with role-scoped modules | Seven UIs, one frontend toolchain; to be served as static assets from the cluster |
| Code location | **`amisad.dev/poc/`** | POC status explicit; planning docs and code in one repo |
| Kubernetes | **kubeadm**, single-node cluster in one VM (containerd, node-local image registry) | Conformant upstream K8s; nothing cloud-specific; services are reached on NodePorts 30080–30089, no ingress in the POC |
| Database | **PostgreSQL** (one instance, schema per service; a host service on vm-core that in-cluster pods dial over the node network) | Sole database per principles; ledgers as append-only hash-chained tables, with the app role denied UPDATE/DELETE so append-only is database-enforced |
| Events | **NATS JetStream** (a host service on vm-core, provisioned but not yet carrying traffic) | One lightweight broker; persistent streams are what will give the idempotent replay s007.inventory asserts. The POC exchanges the same events as direct fire-and-forget HTTP notifies, and s007's replay idempotency is enforced consumer-side today |
| Identity | **identity-mock**, a Rust token issuer | In-stack mock of Identity & Verification; issues opaque bearer tokens carrying actor + class and verifies them by lookup (JWT encoding, expiry, and class enforcement are growth-path); swappable for carrier federation |
| API style | Versioned REST/JSON under `/v1`, OpenAPI-documented, contracts checked in under `poc/contracts/` | Per principles; the contract files are the compatibility gate |

## 2. POC topology

Four VMs plus the dev host, all provisioned and driven by Yuruna (see [design/01-overview.md](design/01-overview.md) for the diagrams):

| Node | Role |
|------|------|
| **Dev host** | Yuruna test runner, status service, binary stash service, VM provisioning (Hyper-V/KVM/UTM — any supported host) |
| **vm-build** | Rust toolchain only: compiles the workspace once per run and uploads the binaries tarball to the stash service |
| **vm-core** | Kubernetes cluster: the seven server-side application services, foundation services, PostgreSQL, NATS; no source build and no Rust toolchain |
| **vm-edge-a**, **vm-edge-b** | Two "slice VMs" — the telco-local edge, one per simulated region/jurisdiction |
| **Test mobile device** | Flutter buyer app, side-loaded, reaching vm-core over the lab LAN — a by-hand demo path, outside the automated run |

Splitting compilation onto **vm-build** keeps vm-core close to a production node: it receives binaries, builds thin images from them, and never holds a compiler.

Two edge VMs are the minimum honest topology: s004.failover requires a jurisdiction-restricted allocation choosing between regions, and s009.suppression requires one region above and one below the anonymity threshold.

**Slice VMs stay stateless.** Each runs only the `slice-runtime` binary, delivered per run over SSH: it accepts an allocation from the fabric coordinator and, per dispatch, runs one **ephemeral match environment** (simulated enclave) that opens the envelope, reports its attestation lifecycle, emits the match record, and drops every trace of its state when it answers. The environment is logical — one request inside a persistent process rather than a process per match — and hardware isolation is what the growth path swaps in. No database, no persistent volume, no queue on the edge; a rebooted slice VM is indistinguishable from a fresh one.

## 3. Application inventory

Every application from [applications.md](applications.md) exists in the POC — s001…s010 assert against all of them, and the principles forbid stubbing anything a scenario asserts against.

| Application | POC realization | UI |
|-------------|-----------------|----|
| AmisAd/buyer | Two clients over one contract: `buyer-client`, a headless Rust CLI that drives every buyer, delegate, and consent path the scenarios assert; and a Flutter app carrying the need → match → status path for the by-hand demo | CLI (automation) + mobile (side-loaded) |
| AmisAd/seller | `seller-svc`: catalog, inventory, order state machine, settlement confirmation, demand-outlook view | SPA module |
| AmisAd/resource | `resource-svc`: edge registry, allocation policy, jurisdiction-checked placement, telemetry, incidents | SPA module |
| AmisAd/ads | `ads-svc`: campaign + creative-studio modes, asset store, budget pacing, attribution reports | SPA module |
| AmisAd/insights | `insights-svc`: threshold-enforcing aggregation pipeline, workbench, outlook publisher | SPA module |
| AmisAd/platform | `platform-svc`: cross-party incident cases, support desk, time-boxed disclosure flow | SPA module |
| AmisAd/audit | `audit-svc`: chain verifier, certification runner, tamper localization — read-only by construction | SPA module |
| AmisAd/connect | `connect-svc`: versioned contracts, sandbox partners, scoped credentials, order mirroring | SPA module |

The buyer application deliberately has **no dedicated backend service**: the vault lives on the device, and the client talks only to `identity-mock` (its token) and the fabric coordinator, which is its single surface — need envelopes, shortlists, bookings, consent and mandate records (relayed to `ledger-svc` under a pseudonymous subject), the per-handle notification log, and pseudonymous order status. So there is no server-side store of buyer needs to protect, in the POC or ever.

## 4. Foundations realization

- **Private Matching Fabric** = `fabric-coordinator` (in-cluster) + `slice-runtime` (edge VMs). The buyer client seals the need into an **envelope addressed to the ephemeral environment**; the coordinator picks a slice per jurisdiction policy (from `resource-svc`) and routes the envelope; only the environment opens it. Core services never hold plaintext needs — the coordinator carries the envelope as an opaque string and never parses it, which is checkable in the code and by the egress assert (envelope cryptography itself is a growth-path item). Offers and active campaign creative travel in with it; the match record or shortlist, the settlement instruction, and the attestation trail travel out; the environment's `created → attested → executed/aborted → destroyed` lifecycle is written to the attestation ledger and mirrored to `resource-svc` as telemetry. Mandate scope (s006) is evaluated by the coordinator *before* dispatch, so an out-of-scope delegated need creates no environment at all.
- **Identity & Verification** = `identity-mock`: issues opaque bearer tokens carrying an actor and its class and verifies them by lookup. The four actor classes (person, organization, delegate-bound-to-principal, workload) are the contract callers are written against; the POC issuer records the class without enforcing it, delegate binding lives in the coordinator's mandate scope, and connector credentials are minted by `connect-svc` against the seller's grant. Production replaces the issuer, not the token contract.
- **Consent Ledger + Settlement & Attribution Ledger + attestation log** = `ledger-svc`: three append-only, hash-chained PostgreSQL table families behind one Rust service. Writes are inserts only; balances and views are derived; disputes land as compensating entries referencing their case; the raw chains are exposed for `audit-svc` to recompute independently. Consent carries four grant types — participation, contribution, mandate, disclosure — folded newest-wins per subject. No blockchain.
- **Event backbone** = NATS JetStream subjects per domain (`orders.*`, `inventory.*`, `campaigns.*`, `cases.*`), consumed idempotently, with `connect-svc` webhook delivery and replay riding the same streams. The broker runs on vm-core, and the POC carries those events as direct fire-and-forget HTTP notifies between the same pairs (seller → coordinator on offer publication, seller → connect on order transitions) — sender-detached so no two single-threaded services can deadlock, and idempotent at the consumer, which is what makes the JetStream swap a transport change rather than a design change.

## 5. Mock boundary

Every mock implements the production interface; swapping it changes no caller.

| Production capability | POC stand-in | Preserved contract |
|-----------------------|--------------|--------------------|
| TEE / confidential computing | `slice-runtime` request-scoped environments + **attestation simulator** | Attestation record schema, lifecycle states, chain format |
| Carrier network slices | Edge VMs registered with `resource-svc`; the runtimes are placed there per run | Allocation API, jurisdiction constraint evaluation, telemetry stream |
| SIM-anchored identity | `identity-mock` token issuer | Token claims, actor classes, verification states |
| Payments | Settlement-ledger entries only; no money moves | Split computation, compensating-entry adjustments |
| On-device matching | Always matched on edge slices in POC | Envelope opacity end to end; the vault never syncs server-side |
| Creative production tooling | Metadata + a creative reference in the `ads-svc` asset store | Brief → draft → approved → placed lifecycle, environment ingress |

## 6. Repository layout

The POC mirrors the **yuruna-project convention** (components / config /
workloads / test) so the Yuruna runner discovers and drives it, with **Bazel**
(pinned via bazelisk) as the single build entry point:

```
amisad.dev/
  plan/                     # planning docs (this file, personas, applications, scenarios, design/)
  poc/
    MODULE.bazel            # Bazel root (bzlmod, rules_rust pinned; .bazelversion via bazelisk)
    build/                  # doctor.ps1 (toolchain check), build-all.ps1, images.ps1,
                            #   run-tests.ps1 (scenario driver), serve-local.ps1
    contracts/              # OpenAPI specs — the compatibility gate; NATS event schemas land
                            #   with the first scenario that publishes on a subject
    components/
      services/             # 10 Rust services (seller-svc … ledger-svc)
      edge/slice-runtime/   # stateless edge match runtime (Rust, same workspace)
      apps/buyer-client/    # headless buyer (Rust CLI) driving the scenario sequences
      apps/buyer-flutter/   # Flutter buyer app (Android side-loaded)
      apps/web-spa/         # React+TS+Vite shell; the seven module routes are placeholders
      lib/amisad-common/    # shared config/health plumbing crate
      art/                  # canonical brand assets + palette tokens (from amisad.com)
    config/localhost/       # three-phase deploy config (resources → components → workloads)
    workloads/services/     # minimal Helm chart per service
    db/                     # schema.sql (hash-chained ledgers) + per-scenario seeds
    test/                   # Yuruna sequences (workload.guest.*.yml): the topology tiers
                            #   (build baseline/compile, core k8s/deploy, edge-a/-b) + s001…s010
    test/ubuntu.server.24/  # guest scripts the sequences fetch-and-execute
    demo/                   # browser-driven walkthroughs over the topology a green run leaves live
```

## 7. Scenario execution

Yuruna provisions the nodes, deploys the ten services onto vm-core, and executes [scenarios.md](scenarios.md) as its discovered sequences — s001…s009 in priority order, then s010.certification. Each scenario **restores the deployed `amisad-core` snapshot first**, and that restore *is* the state reset, so the scenarios are order-independent and each seeds the state its steps need through the `/v1` APIs (the SQL files under `poc/db/seed/` are the relational sketch of the same seeds, for direct-SQL use). Because the reset discards what the run before it produced, s010.certification self-seeds a representative corpus spanning its four dimensions — a completed match plus an injected abort, consent grant and revocation, a mandate, a disclosure and its adjustment — and certifies that. Each scenario's Target Verification Point maps to asserts against observable state: ledger sums and chain verification via `ledger-svc`/`audit-svc` APIs, rows read straight out of PostgreSQL, environment lifecycles via the attestation ledger, application state via the `/v1` APIs, and the slice VMs' egress logs for the zero-leak assertions.

## 8. Growth path

| POC | Full system |
|-----|-------------|
| Single-node kubeadm cluster in one VM, NodePorts | Conformant managed or self-run K8s on any cloud behind an ingress — the no-managed-services rule keeps the manifests portable |
| Two edge VMs | Carrier MEC sites with hardware TEEs — attestation simulator swapped for real quotes, same schema |
| `identity-mock` | Carrier identity federation behind the same token contract |
| One PostgreSQL instance | Per-service clusters; ledger schemas unchanged |
| Side-loaded Android build | Store-distributed Android + iOS from the same Flutter codebase |
| SPA shell with placeholder module routes | The seven workspaces built out, served from the cluster, then behind a CDN |
| Yuruna lab sequences | The same sequences as staging/production conformance gates |

## 9. Diagrams

The documents under [design/](design/) visualize this design; they do not restate it. Every application diagram holds at most seven boxes (the topology diagram maps one box per lab node); **dashed edges and boxes mark what is designed but not built** — growth-path items, and surfaces this design fixes that the POC reaches by another route. Solid means the code does exactly that.

| # | Document | Diagram type | Shows |
|---|----------|--------------|-------|
| 1 | [POC overview](design/01-overview.md) | flowchart ×2 | The seven top-level POC blocks; the lab deployment topology. |
| 2 | [AmisAd/buyer](design/02-buyer.md) | flowchart | Buyer clients: matching path, consent and mandate controls, delegate mode. |
| 3 | [AmisAd/seller](design/03-seller.md) | flowchart | seller-svc: catalog, inventory, order state machine, settlement. |
| 4 | [AmisAd/resource](design/04-resource.md) | flowchart | resource-svc: policy, placement, telemetry, incidents. |
| 5 | [AmisAd/ads](design/05-ads.md) | flowchart | ads-svc: campaign + studio modes, assets, attribution. |
| 6 | [AmisAd/insights](design/06-insights.md) | flowchart | insights-svc: threshold pipeline, workbench, outlooks. |
| 7 | [AmisAd/platform](design/07-platform.md) | flowchart | platform-svc: operations + support desk, registry, adjustments. |
| 8 | [AmisAd/audit](design/08-audit.md) | flowchart | audit-svc: chain verification, certification, reporting. |
| 9 | [AmisAd/connect](design/09-connect.md) | flowchart | connect-svc: contracts, sandbox, credentials, webhooks. |

One sequence diagram per verification scenario, faithful to the numbered steps in [scenarios.md](scenarios.md): participants are the POC components above, personas are actors, at most 8 lifelines each, and each diagram traces its scenario's steps to its Target Verification Point.

| Document | Sequence for |
|----------|--------------|
| [seq.s001.fulfillment.md](design/seq.s001.fulfillment.md) | s001.fulfillment — Intent-Driven Edge Match and Automated Fulfillment |
| [seq.s002.fitting.md](design/seq.s002.fitting.md) | s002.fitting — Considered Purchase, Constraint Fidelity, and In-Person Booking |
| [seq.s003.silence.md](design/seq.s003.silence.md) | s003.silence — Consent Revocation and the Right to Silence |
| [seq.s004.failover.md](design/seq.s004.failover.md) | s004.failover — Sovereign Slice Allocation, Isolation Fault, and Attested Failover |
| [seq.s005.attribution.md](design/seq.s005.attribution.md) | s005.attribution — Campaign-Boosted Match, Edge Creative Serving, and Attribution Credit |
| [seq.s006.mandate.md](design/seq.s006.mandate.md) | s006.mandate — Delegated Procurement Under a Scoped Mandate |
| [seq.s007.inventory.md](design/seq.s007.inventory.md) | s007.inventory — Enterprise Integration Onboarding and Inventory-Truth Matching |
| [seq.s008.mediation.md](design/seq.s008.mediation.md) | s008.mediation — Zero-Knowledge Dispute Mediation and Settlement Adjustment |
| [seq.s009.suppression.md](design/seq.s009.suppression.md) | s009.suppression — Aggregate Insight Publication and the Demand-Planning Loop |
| [seq.s010.certification.md](design/seq.s010.certification.md) | s010.certification — Independent Certification of the Full Evidence Trail |

How the documents relate:

- Doc 1 names the blocks and places them on the lab network; docs 2–9 open one application each.
- Foundation services (`fabric-coordinator`, `slice-runtime`, `identity-mock`, `ledger-svc`) appear as external boxes in every application diagram — they are defined in §4 above and drawn open in doc 1.
- Scenario coverage per application is listed at the bottom of each document, tracing back to [scenarios.md](scenarios.md).
- The seq.\* documents show docs 2–9's components exchanging messages in scenario order: each opens with a Note stating seeded preconditions and closes with a Note stating the Target Verification Point Yuruna asserts.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
