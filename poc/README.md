# AmisAd POC

Code skeletons for the AmisAd proof of concept, laid out in the
**yuruna-project convention** so the Yuruna runner discovers and drives them.
Design: [../plan/design.md](../plan/design.md) · scenarios:
[../plan/scenarios.md](../plan/scenarios.md).

## Layout

| Path | Contents |
|------|----------|
| `MODULE.bazel`, `.bazelversion`, `BUILD.bazel` | Bazel root (bzlmod, pinned via bazelisk) |
| `build/` | `doctor.ps1` (toolchain check), `build-all.ps1`, `images.ps1` |
| `contracts/` | OpenAPI stubs per service (`/health`, `/version`) + event-schema placeholders |
| `components/services/` | 10 Rust services (seller, resource, ads, insights, platform, audit, connect, fabric-coordinator, identity-mock, ledger-svc) |
| `components/edge/slice-runtime/` | Stateless edge match runtime (Rust) |
| `components/apps/buyer-flutter/` | Flutter buyer app (Android side-loaded) |
| `components/apps/web-spa/` | React + TS + Vite shell, 7 role-scoped module routes |
| `components/lib/amisad-common/` | Shared config/health plumbing crate |
| `components/art/` | Brand assets from amisad.com + palette tokens (canonical) |
| `config/localhost/` | Three-phase deploy skeletons (resources → components → workloads) |
| `workloads/services/` | Minimal Helm chart per service (liveness probe on `/health`) |
| `db/` | `schema.sql` (schemas + hash-chained ledger tables) + per-scenario seed skeletons |
| `test/gui/` | Yuruna sequences: baseline (`k8s.amisad` snapshot) + SCENARIO-001…010 |
| `test/ubuntu.server.24/` | Guest scripts the sequences fetch-and-execute |

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

- **No third-party crates yet.** The services serve `/health`/`/version` with
  a std-only responder in `amisad-common`, so the first build needs no crate
  fetches and no lockfile. Wire **crate_universe** in `MODULE.bazel` together
  with the first real dependency (Actix lands with the first real routes —
  plan/design.md §1).
- **App builds are `bazel run` wrappers.** Flutter and Vite have no mature
  Bazel rules, and their toolchains fight sandboxing (Gradle/pub/npm caches).
  `sh_binary` wrappers keep Bazel as the single entry point without lying
  about hermeticity; `build-all.ps1` runs all three stages.
- **Flutter platform scaffolding is hydrated, not committed.** `build.sh`
  runs `flutter create --platforms=android .` on first build; only
  `pubspec.yaml`, `lib/`, and `assets/` are source of truth.
- **Sequences deploy then verify `/health` only** (scenarios 002–010). Each
  scenario sequence restores the `k8s.amisad` snapshot (Kubernetes +
  PostgreSQL + NATS), runs the shared deploy script, and checks the services
  that scenario traverses. The real steps are enumerated as TODO blocks
  pointing at [../plan/scenarios.md](../plan/scenarios.md).

## SCENARIO-001 implementation notes

SCENARIO-001 is implemented end to end: `buyer-client` (the headless buyer)
submits Maya's gift need as an opaque envelope; the coordinator verifies the
token, gets a jurisdiction-checked placement, and dispatches envelope + offers
to `slice-runtime`; the environment matches, attests its full lifecycle,
emits the settlement instruction, and destroys itself; seller fulfillment
confirms the four-way split on the hash-chained ledger. Two sequences drive
it in VMs: `...build.amisad.baseline` (toolchains, snapshot `build.amisad`)
and `...build.amisad.scenario-001` (PAT clone, `bazel build //...`,
`cargo test --workspace`, deploy, happy path, full Target Verification Point).

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
  the JetStream wiring lands with the event-driven scenarios (003+).
- **Logical ephemeral environments.** `slice-runtime` is a persistent edge
  process; each request runs one attested created→attested→executed→destroyed
  environment whose state drops at response time.
- **Single-VM degraded mode.** With `edgeHost` unset, the scenario runs
  slice-runtime on the build VM and says so; setting `edgeHost` (ssh target)
  runs it on a real second VM per the design topology.
