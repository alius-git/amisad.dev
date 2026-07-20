# AmisAd POC

Code skeletons for the AmisAd proof of concept, laid out in the
**yuruna-project convention** so the Yuruna runner discovers and drives them.
Design: [../plan/design.md](../plan/design.md) · scenarios:
[../plan/scenarios.md](../plan/scenarios.md).

## Layout

| Path | Contents |
|------|----------|
| `MODULE.bazel`, `.bazelversion`, `BUILD.bazel` | Bazel root (bzlmod, pinned via bazelisk) |
| `build/` | `doctor.ps1` (toolchain check), `build-all.ps1`, `images.ps1`, `serve-local.ps1` (lab-mode guest source, served from HEAD) |
| `contracts/` | OpenAPI specs per service — real `/v1` routes for the implemented scenarios, `/health`/`/version` stubs for the rest — + event-schema placeholders |
| `components/services/` | 10 Rust services (seller, resource, ads, insights, platform, audit, connect, fabric-coordinator, identity-mock, ledger) |
| `components/edge/slice-runtime/` | Stateless edge match runtime (Rust) |
| `components/apps/buyer-client/` | Headless buyer (Rust CLI) — drives the s001.fulfillment, s002.fitting, and s003.silence paths |
| `components/apps/buyer-flutter/` | Flutter buyer app (Android side-loaded) |
| `components/apps/web-spa/` | React + TS + Vite shell, 7 role-scoped module routes |
| `components/lib/amisad-common/` | Shared config/health plumbing crate |
| `components/art/` | Brand assets from amisad.com + palette tokens (canonical) |
| `config/localhost/` | Three-phase deploy skeletons (resources → components → workloads) |
| `workloads/services/` | Minimal Helm chart per service (liveness probe on `/health`) |
| `db/` | `schema.sql` (schemas + hash-chained ledger tables) + per-scenario seed skeletons |
| `test/gui/` | Active Yuruna sequences: the topology chains (amisad-vm-build, -core k8s/deploy, -edge-a/b) + s001.fulfillment, s002.fitting, s003.silence |
| `test/gui-parked/` | Skeleton sequences (deploy + `/health` checks), un-parked as each scenario is implemented |
| `test/ubuntu.server.24/` | Guest scripts the sequences fetch-and-execute |
| `demo.md` / `test.md` / `usernames.md` | Running the demo by hand · test automation · guest username map |

## Building

```
build/doctor.ps1        # verify toolchains (bazelisk, cargo, node/npm, flutter REQUIRED)
build/build-all.ps1     # doctor -> bazel build //... -> app wrappers
build/images.ps1        # docker images (optional; Docker required)
```

`bazel build //...` builds the entire Rust workspace via rules_rust. Cargo
works directly too (`cargo build --workspace`) — the two share the same
sources.

## Deliberate skeleton choices

- **One third-party crate: `postgres`.** The services serve their routes with
  the std-only responder in `amisad-common`; the first external dependency is
  the PostgreSQL client for the durable ledger/catalog stores, wired through
  **crate_universe** in `MODULE.bazel` with the committed `Cargo.lock` —
  exactly the growth path this bullet used to plan. (Actix replaces the
  responder when the surface outgrows it — plan/design.md §1.)
- **App builds are `bazel run` wrappers.** Flutter and Vite have no mature
  Bazel rules, and their toolchains fight sandboxing (Gradle/pub/npm caches).
  `sh_binary` wrappers keep Bazel as the single entry point without lying
  about hermeticity; `build-all.ps1` runs all three stages.
- **Flutter platform scaffolding is hydrated, not committed.** `build.sh`
  runs `flutter create --platforms=android .` on first build; only
  `pubspec.yaml`, `lib/`, and `assets/` are source of truth.
- **Sequences deploy then verify `/health` only** (scenarios s004–s010,
  parked under `test/gui-parked/`). Each parked skeleton still targets the
  k8s tier; the rework needed to activate one is the checklist in
  [test.md](test.md). The real steps are enumerated as TODO blocks pointing
  at [../plan/scenarios.md](../plan/scenarios.md).

## Running it

- **Test automation** (clean machine → build the design topology → every
  implemented scenario against `amisad-vm-core`, each restoring its snapshot
  as the state reset): [test.md](test.md).
- **Demo by hand** (prebuild once, then drive the deployed topology manually,
  including the mobile app): [demo.md](demo.md).
- **Hostnames + usernames** (per-VM `<hostname>-admin` + the `maya`/`elena`
  demo personas, and why): [usernames.md](usernames.md).

The lab builds the design topology
([plan/design/01-overview.md](../plan/design/01-overview.md)):
`amisad-vm-build` compiles the workspace and uploads the binaries tarball to
the stash service (`yuruna-stash-service`, durable per-upload record);
`amisad-vm-core` downloads it, builds thin distroless images, and deploys the
ten services; `amisad-vm-edge-a`/`-b` are the stateless region slice VMs
(`slice-runtime` delivered per scenario run over SSH). Scenarios run against
`amisad-vm-core`, each restoring its snapshot as the state reset. Hostnames,
per-VM `<hostname>-admin` accounts, and the `maya`/`elena` demo users are in
[usernames.md](usernames.md).

## s001.fulfillment implementation notes

s001.fulfillment is implemented end to end: `buyer-client` (the headless buyer)
submits Maya's gift need as an opaque envelope; the coordinator verifies the
token, gets a jurisdiction-checked placement, and dispatches envelope + offers
to `slice-runtime`; the environment matches, attests its full lifecycle,
emits the settlement instruction, and destroys itself; seller fulfillment
confirms the four-way split on the hash-chained ledger. It spans the topology
(amisad-vm-build → stash → amisad-vm-core, with slice-runtime on
amisad-vm-edge-a — see "Running it" above), asserting the full Target
Verification Point at the end.

Deviations from the target design, deliberate and to be retired in later
scenarios — the wire contracts (`contracts/openapi/`) are unchanged by all of
them:

- **PostgreSQL for the ledgers and the seller; in-memory for the rest.**
  ledger-svc and seller-svc write through to the vm-core PostgreSQL
  (`DATABASE_URL` from the helm values; `db/schema.sql`) and reload on start —
  chains, orders, and offers survive pod restarts, and the app role has no
  UPDATE/DELETE on ledger tables, so append-only is database-enforced.
  Without `DATABASE_URL` the same binaries run in-memory (that is how
  `cargo test` stays hermetic). resource-svc and identity-mock keep in-process
  state behind the real APIs.
- **Envelope opacity instead of encryption.** Upstream services carry the
  envelope as an opaque string and never parse it (checkable in code and by
  the egress assert); actual envelope crypto is TODO.
- **Direct HTTP events, not NATS yet.** Order status flows by polling;
  s003.silence's offer-published event is a direct fire-and-forget HTTP
  notify from seller-svc to the coordinator (a detached thread, so the two
  single-threaded services cannot deadlock). The JetStream wiring stays a
  later step.
- **Logical ephemeral environments.** `slice-runtime` is a persistent edge
  process; each request runs one attested created→attested→executed→destroyed
  environment whose state drops at response time.
- **Real edge, degraded fallback.** slice-runtime runs on `amisad-vm-edge-a`
  per the design topology (resolved via its status-server IP report); if the
  edge is unreachable the scenario falls back to running it on vm-core and
  says so.

## s002.fitting implementation notes

s002.fitting adds the manual-policy path on the same services: the sealed
environment evaluates the extended constraints (required attributes,
exclusions, fitting availability) and, for a manual need, returns a
**shortlist** and commits nothing — no match id, no settlement instruction.
The buyer's explicit booking (`buyer-client book`) is the commitment: the
coordinator posts the settlement instruction (splits shared with the sealed
auto path via `amisad-common`), creates the seller order with an
**identity-free appointment** (slot id + day), and delivers the second of
exactly two notifications (`shortlist`, `booking-confirmed`) on its per-handle
log — the buyer's only surface. Elena advancing the order to fulfilled settles
the split as in s001.

## s003.silence implementation notes

s003.silence makes consent the third hash-chained ledger and the fabric's
execution-time gate. A need with no fitting offer now stays **open** on the
coordinator; publishing an offer fires an offer-published event that re-runs
matching over the open needs — and the consent check inside that cycle is
what makes revocation *silent*: `buyer-client pause` appends a participation
revocation (keyed by a pseudonymous subject hash, never a name), after which
a perfectly fitting new offer produces no environment, no match, and no
notification, while the pre-revocation order still settles normally.
`withdraw` ends aggregate contribution (insights-svc's minimal aggregation
cycle counts only consent-contributing open needs — counts, never content);
`resume` re-grants and the coordinator immediately re-serves the open needs.
The TVP asserts zero attestation-ledger growth across the paused window, the
full grant → revoke → re-grant history on the verifying consent chain, and
its rows in PostgreSQL.

s003-specific deviations, deliberate: the coordinator's open needs are
in-memory (a pod restart drops them while the consent chain persists);
bookings still ride the handle as bearer and are not consent-gated (the
booking step's consent check is future work); and the subject pseudonym is an
unsalted hash of the verified actor with a world-readable per-subject consent
history — pseudonymous, not anonymous.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
