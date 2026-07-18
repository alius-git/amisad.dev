# SCENARIO-001 unattended run — status

**Updated:** 2026-07-18 ~18:45 local · **Result: RUN IN PROGRESS — elevated runner live, iterating**

## Live-run iteration log (newest first)

- **Cycle 245**: `Start-VM` failed — stale Hyper-V disk lock from the prior
  cycle's teardown (infrastructure transient, not code). Retrying via
  commit-triggered resume.
- **Cycle 244**: chain green through BOTH baselines (`k8s.amisad` and
  `build.amisad` snapshots saved — db fix held). Scenario step failed:
  Bazel's bundled JVM lacks the caching proxy's CA (PKIX on
  `bcr.bazel.build`). Fixed in `9cc77f8`: `ca-certificates-java` +
  `--host_jvm_args` truststore, cargo fallback, and one-compile thin
  runtime images (timeout de-risk).
- **Cycle 243**: DB bring-up failed — `sudo -u postgres` cannot read under
  the 0750 login home. Fixed in `c5903d8`: schema fetched host-side into
  `/tmp`, `ON_ERROR_STOP` added.
- **Cycles 241–242**: vacuous passes exposed the missing cycle plan;
  `test/test.runner.yml` added in `ab4da71`.
- Elevation obtained via operator-approved UAC prompt; runner launched
  through `test/status/launch-runner.ps1`.

---

**Earlier (pre-elevation) status follows.**

## TL;DR

Everything that can be proven without Hyper-V is proven green. The VM run
needs one command from an **elevated** PowerShell (this session is
UAC-filtered; `/RL HIGHEST` task creation is denied on this Windows build,
the VS-installer elevation path failed the same way, and the single UAC
consent prompt raised at kickoff was canceled/timed out):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File c:\git\yuruna\test\status\launch-runner.ps1
```

Then watch `http://localhost:8080/status/`. The first cold chain
(start.guest → k8s.amisad → build.amisad → scenario-001) takes 1.5–2 h;
green ends with `SCENARIO-001 HAPPY PATH PASSED` in the cycle log. A watcher
in the automation session polls for runner activity and resumes monitoring
automatically if it appears.

## Host-side verification — all green

| Gate | Result |
|------|--------|
| `cargo check --workspace --all-targets` | Clean, 13 crates, zero errors, first pass |
| `cargo test --workspace` (stable-gnu toolchain) | **17/17 tests pass** — SHA-256 FIPS vectors, ledger chain + tamper detection, constraint matching, auto-close policy, splits, state machine, identity, placement |
| Sequence schema validation (real jsonschema, Python) | 3/3 active sequences valid |
| `helm lint` | 10/10 service charts pass |
| Served tarball | LF-verified; published for HEAD |

## What is armed

- **Yuruna config** (`c:\git\yuruna\test\test.config.yml`): `projectUrl` →
  `C:/git/alius-git/amisad.dev` (local), `GH_TOKEN` set (PAT), guest list
  trimmed to `guest.ubuntu.server.24`, `shouldStopOnFailure: true`,
  `cycleDelaySeconds: 60`, `stepTimeoutMinutes: 75`.
- **Auth vault**: `amisad-pat` (operator-owned key) holds the PAT for the
  production GitHub-clone path; lab mode doesn't need it.
- **Guest source (lab mode)**: guest fetches
  `/yuruna-repo/project-poc.tar.gz` from the host status server;
  `poc/build/serve-local.ps1` republishes from HEAD after every commit
  (currently published).
- **Sequences**: `build.amisad` pair + two chained baselines active; ten
  skeleton scenario sequences parked in `poc/test/gui-parked/`.
- Notification `transports.yml` bootstrapped (warning silenced).

## Runner forensics (why it isn't already running)

The operator's own runner ran cycles 237–240 this morning (old project),
was **paused at 13:02** and its outer loop **stopped ~13:59** — before this
session started. Removing `control.cycle-pause` did not revive it (outer
loop is dead; only the status service still answers on 8080). Starting a
new runner requires Hyper-V, hence Administrator.

## Changes made (committed locally to main, NOT pushed)

- `ced640c` — park skeleton sequences; lab-mode host-served guest source +
  `poc/build/serve-local.ps1`; sequence header documents lab vs production.
- `0e73ab6` — `.gitattributes` forcing LF for guest-consumed files
  (**important**: `core.autocrlf` would otherwise ship CRLF bash into the
  guest and break every script under `set -e`).
- (this commit) — this status file.
- Yuruna side (runtime, not framework code): `test/test.config.yml` edits
  above; vault entry; `test/status/launch-runner.ps1`;
  `project-poc.tar.gz` at the yuruna root. Removed the stale
  `control.cycle-pause` marker.
- Host toolchains installed via winget for verification: rustup
  (+ stable-gnu), bazelisk, Python 3.12, helm. VS Build Tools did NOT
  install (its installer also needs elevation).

## Next steps after the elevated start

1. First cycle: watch the chain build (`start.guest` → `k8s.amisad` →
   `build.amisad`), then the scenario step (build ~15–25 min in-VM, then
   deploy + happy path + TVP asserts).
2. If the scenario step fails: fix in `C:\git\alius-git\amisad.dev`, commit,
   run `poc\build\serve-local.ps1`, let the next cycle retry (warm-paths
   from `build.amisad`, so retries cost ~20–30 min, not 2 h).
3. When green: consider restoring `cycleDelaySeconds: 300` and
   `shouldStopOnFailure: false`, and un-parking sequences as later
   scenarios are implemented.

## Reminders

- **Rotate the PAT after this lab run** (it exists in the automation
  session transcript).
- If any framework operation fails using `GH_TOKEN` against the `yurunadev`
  repos, blank `GH_TOKEN` — prior runs worked with it empty.
- Framework checkout is 1 commit behind upstream (left un-pulled on
  purpose; don't update mid-lab).
