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
| `contracts/` | OpenAPI specs per service — real `/v1` routes for the SCENARIO-001 services, `/health`/`/version` stubs for the rest — + event-schema placeholders |
| `components/services/` | 10 Rust services (seller, resource, ads, insights, platform, audit, connect, fabric-coordinator, identity-mock, ledger) |
| `components/edge/slice-runtime/` | Stateless edge match runtime (Rust) |
| `components/apps/buyer-client/` | Headless buyer (Rust CLI) — drives the SCENARIO-001 happy path |
| `components/apps/buyer-flutter/` | Flutter buyer app (Android side-loaded) |
| `components/apps/web-spa/` | React + TS + Vite shell, 7 role-scoped module routes |
| `components/lib/amisad-common/` | Shared config/health plumbing crate |
| `components/art/` | Brand assets from amisad.com + palette tokens (canonical) |
| `config/localhost/` | Three-phase deploy skeletons (resources → components → workloads) |
| `workloads/services/` | Minimal Helm chart per service (liveness probe on `/health`) |
| `db/` | `schema.sql` (schemas + hash-chained ledger tables) + per-scenario seed skeletons |
| `test/gui/` | Active Yuruna sequences: `k8s.amisad` and `build.amisad` baselines + SCENARIO-001 |
| `test/gui-parked/` | Skeleton sequences (deploy + `/health` checks), un-parked as each scenario is implemented |
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

- **No third-party crates yet.** The services serve their routes — including
  the full SCENARIO-001 `/v1` surface — with a std-only responder in
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
- **Sequences deploy then verify `/health` only** (scenarios 002–010,
  parked under `test/gui-parked/`). Each
  scenario sequence restores the `k8s.amisad` snapshot (Kubernetes +
  PostgreSQL + NATS), runs the shared deploy script, and checks the services
  that scenario traverses. The real steps are enumerated as TODO blocks
  pointing at [../plan/scenarios.md](../plan/scenarios.md).

## Running scenarios under Yuruna (common setup)

One-time lab setup on the operator machine; every scenario sequence reuses it.

1. **Get the framework.** Use the OS one-liner from the Yuruna repo's
   `install/README.md` (Remote one-liners) — it installs dependencies and
   clones the framework to `~/git/yuruna` (`%USERPROFILE%\git\yuruna` on
   Windows).

2. **Point Yuruna at AmisAd.** From the `yuruna` folder:

   ```powershell
   Copy-Item test/test.config.yml.template test/test.config.yml
   ```

   Edit `test/test.config.yml`:
   - `repositories.projectUrl`: `https://github.com/alius-git/amisad.dev.git` —
     the runner clones this into `project/` every cycle and discovers the
     sequences under `poc/test/gui/` automatically.
   - `repositories.GH_TOKEN`: a GitHub PAT with read access to the repo.
     This is the **host** side of PAT access (the runner's own clone).
   - `guestSequence`: trim to `- guest.ubuntu.server.24` — the only guest
     the AmisAd sequences target.

3. **Guest PAT (authentication vault).** Guests never see `GH_TOKEN`; the
   scenario-001 sequence renders the PAT from Yuruna's authentication vault
   via `${ext:authentication.GetPassword(amisad-pat)}` in a `sensitive: true`
   step, so it reaches the guest's git credential store without ever
   appearing in logs or OCR captures. One-time setup, from the `yuruna`
   folder in `pwsh`:

   ```powershell
   Import-Module ./test/extension/authentication/default.psm1
   Set-UserVaultKey -LogicalUser amisad-pat -VaultKey amisad-pat  # operator-owned: never auto-generated
   Set-Password -Username amisad-pat -NewPassword '<the PAT>'
   ```

   Reusing the `GH_TOKEN` PAT is fine; read-only scope recommended. The
   vault is a local, gitignored file.

4. **Validate, then run.**

   ```powershell
   test/Test-Config.ps1
   pwsh test/Invoke-TestRunner.ps1
   ```

   Watch progress at `http://localhost:8080/status/`.

**Baselines are chained, not run by hand.** Every sequence declares its
prerequisites; the runner walks the chain cold once, then warm-paths from
disk snapshots (`requiresSnapshot`):

```
start.guest.ubuntu.server.24
  -> k8s.amisad     (Kubernetes + PostgreSQL + NATS)
  -> build.amisad   (rustup 1.83, bazelisk, git, python3)   <- the "build VM"
  -> scenario sequences
```

So "building the build VM" is simply the first run of any sequence that
requires the `build.amisad` snapshot: expect the cold path to take well over
an hour; subsequent cycles restore the snapshot and skip straight to the
top-level sequence.

**One guest OS username per final VM.** The top-of-chain `username` variable
cascades all the way down to `start.guest.ubuntu.server.24`, so each
top-level sequence provisions its base VM under its own account with its own
vault entry (`yamisad-build` for the build chain, `yamisad-s001` for the
SCENARIO-001 sequence). This decouples the first-login forced-password
rotation: the base Ubuntu image expires the password on first login, so two
VMs provisioned from the same image under the *same* username fight over one
vault entry — one VM's rotation invalidates what the next expects. Separate
names mean separate vault entries and no cross-VM/cross-run collision.

**Repo delivery: lab iteration mode vs production path.** In lab iteration
mode (current), the guest obtains the repo as a tarball from the host status
server (`/yuruna-repo/project-poc.tar.gz`, regenerated from `amisad.dev`
HEAD by `poc/build/serve-local.ps1` after every commit) — the same channel
fetch-and-execute uses; the guest script does the fetch. The production path
(kept for later) clones GitHub with the vault PAT from step 3 rendered via
`${ext:authentication.GetPassword(amisad-pat)}` in a `sensitive: true` step;
restore it by re-adding the credential-store and git-clone steps to the
scenario sequence.

## SCENARIO-001 implementation notes

SCENARIO-001 is implemented end to end: `buyer-client` (the headless buyer)
submits Maya's gift need as an opaque envelope; the coordinator verifies the
token, gets a jurisdiction-checked placement, and dispatches envelope + offers
to `slice-runtime`; the environment matches, attests its full lifecycle,
emits the settlement instruction, and destroys itself; seller fulfillment
confirms the four-way split on the hash-chained ledger. Two sequences drive
it in VMs: `...build.amisad.baseline` (toolchains, snapshot `build.amisad`)
and `...build.amisad.scenario-001` (repo fetch, `bazel build //...`,
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

### Running SCENARIO-001

With the [common setup](#running-scenarios-under-yuruna-common-setup) done,
the runner discovers and executes
`workload.guest.ubuntu.server.24.build.amisad.scenario-001`, which:

1. restores the `build.amisad` snapshot (building it first if absent);
2. fetches the committed tree to `~/amisad.dev` (lab iteration mode; the
   production PAT clone is described under the common setup above);
3. runs `bazel build //...` and `cargo test --workspace`;
4. deploys the ten services to the in-VM cluster and exposes the NodePorts;
5. starts `slice-runtime` — on the second VM when `edgeHost` is set
   (committed value, since the project is re-cloned each cycle), otherwise
   on the build VM in the documented degraded mode;
6. runs the `buyer-client` happy path and asserts the full SCENARIO-001
   Target Verification Point.

Green means `SCENARIO-001 HAPPY PATH PASSED` in the cycle log, followed by
the saved system diagnostic. Failures leave the VM up for inspection.

### Running the demo by hand

A passing run leaves everything deployed in the VM. NodePorts:
coordinator `30080`, ledger `30081`, resource `30082`, seller `30083`,
identity `30084`.

**Console / ssh (headless demo):**

```bash
cd ~/amisad.dev/poc
export COORDINATOR_URL=http://localhost:30080 IDENTITY_URL=http://localhost:30084
target/release/buyer-client submit          # prints handle + match as JSON
curl -X POST http://localhost:30083/v1/orders/advance -d '{"match_id":"<id>","state":"provisioning"}'
curl -X POST http://localhost:30083/v1/orders/advance -d '{"match_id":"<id>","state":"fulfilled"}'
target/release/buyer-client wait <handle>   # -> status: delivered
```

**Mobile (manual demo):** build and side-load the buyer app against the VM's
LAN address, state a need on the needs screen, and refresh its status while
advancing the order as above:

```bash
cd components/apps/buyer-flutter
flutter build apk --debug \
  --dart-define=COORDINATOR_URL=http://<vm-ip>:30080 \
  --dart-define=IDENTITY_URL=http://<vm-ip>:30084
adb install build/app/outputs/flutter-apk/app-debug.apk
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 alius-git
