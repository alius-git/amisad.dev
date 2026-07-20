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
| `components/apps/buyer-client/` | Headless buyer (Rust CLI) — drives the s001.fulfillment and s002.fitting paths |
| `components/apps/buyer-flutter/` | Flutter buyer app (Android side-loaded) |
| `components/apps/web-spa/` | React + TS + Vite shell, 7 role-scoped module routes |
| `components/lib/amisad-common/` | Shared config/health plumbing crate |
| `components/art/` | Brand assets from amisad.com + palette tokens (canonical) |
| `config/localhost/` | Three-phase deploy skeletons (resources → components → workloads) |
| `workloads/services/` | Minimal Helm chart per service (liveness probe on `/health`) |
| `db/` | `schema.sql` (schemas + hash-chained ledger tables) + per-scenario seed skeletons |
| `test/gui/` | Active Yuruna sequences: build/k8s/core baselines, the build-VM compile, s001.fulfillment, s002.fitting |
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

- **No third-party crates yet.** The services serve their routes — including
  the implemented scenarios' full `/v1` surface — with a std-only responder in
  `amisad-common`, so builds need no crate fetches and no committed lockfile.
  Wire **crate_universe** in `MODULE.bazel` together with the first external
  dependency (Actix replaces the responder when the surface outgrows it —
  plan/design.md §1).
- **App builds are `bazel run` wrappers.** Flutter and Vite have no mature
  Bazel rules, and their toolchains fight sandboxing (Gradle/pub/npm caches).
  `sh_binary` wrappers keep Bazel as the single entry point without lying
  about hermeticity; `build-all.ps1` runs all three stages.
- **Flutter platform scaffolding is hydrated, not committed.** `build.sh`
  runs `flutter create --platforms=android .` on first build; only
  `pubspec.yaml`, `lib/`, and `assets/` are source of truth.
- **Sequences deploy then verify `/health` only** (scenarios s003–s010,
  parked under `test/gui-parked/`). Each parked skeleton still targets the
  k8s tier; the rework needed to activate one is the checklist in
  [test.md](test.md). The real steps are enumerated as TODO blocks pointing
  at [../plan/scenarios.md](../plan/scenarios.md).

## Running it

- **Test automation** (clean machine → build → every implemented scenario,
  fully cold, per-scenario users/VMs): [test.md](test.md).
- **Demo by hand** (prebuild once, then drive the deployed cluster manually,
  including the mobile app): [demo.md](demo.md).
- **Guest usernames** (one per scenario + the build VM, and why):
  [usernames.md](usernames.md).

The build and runtime roles are separate VMs connected through the stash
service (`yuruna-stash-service`), which keeps a durable record of each uploaded
artifact: `amisad.build` compiles the workspace and uploads the binaries
tarball (label `amisad-poc` / `amisad-binaries.tgz`); each scenario VM
downloads it (`GET /api/stashes?username=amisad-poc&filename=amisad-binaries`),
builds thin distroless images, deploys the ten services, and runs the scenario.
`slice-runtime` and `buyer-client` run as bare prebuilt binaries.

## s001.fulfillment implementation notes

s001.fulfillment is implemented end to end: `buyer-client` (the headless buyer)
submits Maya's gift need as an opaque envelope; the coordinator verifies the
token, gets a jurisdiction-checked placement, and dispatches envelope + offers
to `slice-runtime`; the environment matches, attests its full lifecycle,
emits the settlement instruction, and destroys itself; seller fulfillment
confirms the four-way split on the hash-chained ledger. It runs across two VMs
(build + scenario, connected through the stash service — see "Running it"
above), asserting the full Target Verification Point at the end.

Deviations from the target design, deliberate and to be retired in later
scenarios — the wire contracts (`contracts/openapi/`) are unchanged by all of
them:

- **In-memory state, not PostgreSQL.** ledger-svc, seller-svc, resource-svc,
  and identity-mock keep state in process behind the real APIs;
  `db/schema.sql` already holds the target tables.
- **Envelope opacity instead of encryption.** Upstream services carry the
  envelope as an opaque string and never parse it (checkable in code and by
  the egress assert); actual envelope crypto is TODO.
- **Polling instead of NATS events.** Order status flows by HTTP polling;
  the JetStream wiring lands with the event-driven scenarios (s003+).
- **Logical ephemeral environments.** `slice-runtime` is a persistent edge
  process; each request runs one attested created→attested→executed→destroyed
  environment whose state drops at response time.
- **Single-VM degraded mode.** With `edgeHost` unset, the scenario runs
  slice-runtime on the scenario VM and says so; setting `edgeHost` (ssh target)
  runs it on a real edge VM per the design topology.

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

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
