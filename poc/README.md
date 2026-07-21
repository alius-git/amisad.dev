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
| `components/apps/buyer-client/` | Headless buyer (Rust CLI) — drives the s001–s010 buyer, delegate, campaign, and disclosure paths |
| `components/apps/buyer-flutter/` | Flutter buyer app (Android side-loaded) |
| `components/apps/web-spa/` | React + TS + Vite shell, 7 role-scoped module routes |
| `components/lib/amisad-common/` | Shared config/health plumbing crate |
| `components/art/` | Brand assets from amisad.com + palette tokens (canonical) |
| `config/localhost/` | Three-phase deploy skeletons (resources → components → workloads) |
| `workloads/services/` | Minimal Helm chart per service (liveness probe on `/health`) |
| `db/` | `schema.sql` (schemas + hash-chained ledger tables) + per-scenario seed skeletons |
| `test/gui/` | Active Yuruna sequences: the topology chains (amisad-build, -core k8s/deploy, -edge-a/b) + s001.fulfillment … s010.certification |
| `test/gui-parked/` | Empty — every scenario is implemented under `test/gui/` |
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
  **crate_universe** in `MODULE.bazel` with the committed `Cargo.lock`.
  (Actix replaces the
  responder when the surface outgrows it — plan/design.md §1.)
- **App builds are `bazel run` wrappers.** Flutter and Vite have no mature
  Bazel rules, and their toolchains fight sandboxing (Gradle/pub/npm caches).
  `sh_binary` wrappers keep Bazel as the single entry point without lying
  about hermeticity; `build-all.ps1` runs all three stages.
- **Flutter platform scaffolding is hydrated, not committed.** `build.sh`
  runs `flutter create --platforms=android .` on first build; only
  `pubspec.yaml`, `lib/`, and `assets/` are source of truth.
- **All ten scenarios (s001–s010) are implemented and asserted end to end**
  against the design topology; `test/gui-parked/` is now empty. Each scenario
  restores the `amisad-core` snapshot as its state reset and drives the full
  Target Verification Point over SSH ([test.md](test.md)).

## Running it

- **Test automation** (clean machine → build the design topology → every
  implemented scenario against `amisad-core`, each restoring its snapshot
  as the state reset): [test.md](test.md).
- **Demo by hand** (prebuild once, then drive the deployed topology manually,
  including the mobile app): [demo.md](demo.md).
- **Hostnames + usernames** (per-VM `<hostname>-admin` + the maya/elena/tom/priya
  demo personas, and why): [usernames.md](usernames.md).

The lab builds the design topology
([plan/design/01-overview.md](../plan/design/01-overview.md)):
`amisad-build` compiles the workspace and uploads the binaries tarball to
the stash service (`yuruna-stash-service`, durable per-upload record);
`amisad-core` downloads it, builds thin distroless images, and deploys the
ten services; `amisad-edge-a`/`-b` are the stateless region slice VMs
(`slice-runtime` delivered per scenario run over SSH). Scenarios run against
`amisad-core`, each restoring its snapshot as the state reset. Hostnames,
per-VM `<hostname>-admin` accounts, and the demo users (maya, elena, tom, priya) are in
[usernames.md](usernames.md).

## s001.fulfillment implementation notes

s001.fulfillment is implemented end to end: `buyer-client` (the headless buyer)
submits Maya's gift need as an opaque envelope; the coordinator verifies the
token, gets a jurisdiction-checked placement, and dispatches envelope + offers
to `slice-runtime`; the environment matches, attests its full lifecycle,
emits the settlement instruction, and destroys itself; seller fulfillment
confirms the four-way split on the hash-chained ledger. It spans the topology
(amisad-build → stash → amisad-core, with slice-runtime on
amisad-edge-a — see "Running it" above), asserting the full Target
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
- **Real edge, degraded fallback.** slice-runtime runs on `amisad-edge-a`
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

## s004.failover implementation notes

s004.failover proves the fabric fails *safe*. Both edges now run
`slice-runtime` with an attested **region identity**; resource-svc's default
placement is capacity-greedy across regions, and Tom's jurisdiction policy is
what pins the restricted jurisdiction to its compliant region — the roomier
region-b is excluded at allocation time (both facts positively asserted). The
harness arms two consecutive **isolation faults**: each armed environment
self-terminates BEFORE the envelope is opened (created → attested → aborted
→ destroyed, fault reason attested, no match record, nothing need-derived in
the abort trail), the abort telemetry raises incidents in Tom's queue, and
the coordinator's automatic retry (three attempts, same compliant placement)
completes the match with exactly one settlement — hosting revenue for the
completed environment only. Tom escalates the systemic pattern to Priya:
platform-svc's first real surface, a cross-party incident case linking both
aborted lifecycles by environment id only.

## s005.attribution implementation notes

s005.attribution turns ads-svc real and proves attribution survives without
tracking. Marcel creates a campaign and a creative brief; Kai produces an
approved asset; Marcel activates it. The coordinator fetches active campaigns
for the region and passes them INTO the sealed environment, where slice-runtime
boosts a qualifying offer with the creative (logged in the environment
ingress log) - the creative is rendered inside the environment, never outside.
On accept, the booking settles a 5-way split: seller/network/platform from the
offer price as before, plus agency + creator credit funded by the campaign's
per-match commitment ON TOP of the price (seller revenue unchanged). ads-svc
records the attribution, decrements the budget by the commitment (not
impressions), and serves aggregate-only agency/creator dashboards. The TVP
asserts non-zero agency+creator credit referencing campaign+asset ids,
dashboard/ledger consistency, the creative in ingress, and zero buyer signal
on the campaign side.

## s006.mandate implementation notes

s006.mandate adds delegated authority. Maya grants Pat a scoped mandate
(category, per-item cap, expiry) recorded on the consent ledger as a third
grant type ('mandate') and held in the coordinator for scope. Pat's delegate
workspace shows Maya as principal. An in-scope, under-cap need closes on Pat's
authority with dual attribution (actor Pat, principal Maya, mandate ref) on
Maya's activity trail; an over-cap match is HELD - the closing exists only
after Maya's recorded approval; an out-of-scope category is refused at
submission (scope is fabric-enforceable, so it is checked before any
environment - zero environments, zero ledger entries); and revocation clears
the delegate workspace and fails every subsequent delegated attempt
immediately. Booking is generalized to accept a plain accept (no fitting
slot).

## s007.inventory implementation notes

s007.inventory turns connect-svc real and makes external truth govern
matching. Alex registers as a partner (sandbox only) and certifies a
connector; Elena grants scoped credentials (catalog, inventory, orders) capped
to exactly that scope. The connector syncs the ERP catalog into Elena's tenant
and an inventory delta that zeroes the last unit of an item - a zeroed offer
leaves the matchable catalog (seller-svc per-offer stock), so a buyer need
matches only the in-stock alternative even though the zeroed item was cheaper.
Order-lifecycle events mirror to the ERP idempotently (a replayed delivery is
a no-op); an out-of-scope call is refused on credential scope and logged with
nothing returned; and revocation kills the credentials while Elena's catalog
stays intact. No buyer identity or need content crosses the integration
surface. The seller->connect order webhook is a detached best-effort thread,
like the offer-published event.

## s008.mediation implementation notes

s008.mediation proves support cannot become surveillance. A support case opens
in platform-svc carrying operational METADATA only (order state, settlement) -
no buyer identity ever reaches it. When metadata is not enough, Sam requests a
scoped, time-boxed disclosure; Maya grants it through the coordinator, which
records a `disclosure` grant on the consent ledger under her PSEUDONYMOUS
subject and delivers the artifact to the case with an expiry. The refund posts
as compensating settlement entries (negatives) referencing the case - history
is never edited, so the chains still verify and the derived net reflects the
refund. After the grant expires the artifact access path is gone (410). The
consent ledger gains its fourth grant type (`disclosure`), and the settlement
ledger its `adjust` endpoint.

## s009.suppression implementation notes

s009.suppression is the analytics window, and its central assertion is a
SUPPRESSION. insights-svc records demand/supply per (category, region); any
aggregate below the anonymity threshold is omitted entirely - absent from
Dana's workbench, from every published versioned outlook, and from the
unmet-demand flags (never zeroed, indistinguishable from no data). Dana
publishes an immutable versioned outlook; Elena's seller demand-outlook view
and Marcel's ads demand view are thin reads of that same version, so their
figures are identical by construction. The harness proves the below-threshold
region appears in no view anywhere downstream.

## s010.certification implementation notes

s010.certification is the capstone: audit-svc independently re-verifies the
evidence trail across FOUR dimensions - attestation continuity (every
environment's created -> attested -> executed|aborted -> destroyed lifecycle),
residency (region satisfies jurisdiction), consent (chain integrity across all
three grant types), and settlement conservation (splits sum, adjustments are
compensating entries referencing a case, nothing edited) - trusting no
self-report from the ledger (it recomputes the sha256 chains from the raw
dumps). Because each scenario restores a fresh snapshot, s010 self-seeds a
representative corpus (a completed match + an injected abort, consent
grant/revoke, a mandate, a disclosure + adjustment) and certifies THAT. It
localizes a deliberate tamper to the exact modified record, delivers findings
to Priya in the platform, and its own access log proves it only ever read -
no writes, no personal-data scope.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
