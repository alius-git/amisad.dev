# AmisAd POC — test automation

Full automation from a **clean machine** (no pre-built VMs): build once, then
run each implemented scenario in order, each fully cold under its own user.
For running the demo by hand instead, see [demo.md](demo.md).

## One-time setup

1. **Get the framework.** Use the OS one-liner from the Yuruna repo's
   `install/README.md` (Remote one-liners) — it installs dependencies and
   clones the framework to `~/git/yuruna` (`%USERPROFILE%\git\yuruna` on
   Windows).

2. **Point Yuruna at AmisAd.** From the `yuruna` folder:

   ```powershell
   Copy-Item test/test.config.yml.template test/test.config.yml
   ```

   Edit `test/test.config.yml`:
   - `repositories.projectUrl`: `https://github.com/alius-git/amisad.dev.git`
     (or a local clone path) — sequences are discovered under `poc/test/gui/`.
   - `repositories.GH_TOKEN`: a GitHub PAT with read access (host-side clone).
   - `guestSequence`: trim to `- guest.ubuntu.server.24`.

3. **Seed the vault.** From the `yuruna` folder in `pwsh`:

   ```powershell
   Import-Module ./test/extension/authentication/default.psm1
   # Guest PAT for the production clone path (lab mode does not use it):
   Set-UserVaultKey -LogicalUser amisad-pat -VaultKey amisad-pat
   Set-Password -Username amisad-pat -NewPassword '<the PAT>'
   # One keystroke-safe (alphanumeric) password per username — see usernames.md:
   Set-Password -Username yamisad-build -NewPassword '<alnum>'
   Set-Password -Username yamisad-s001  -NewPassword '<alnum>'
   Set-Password -Username yamisad-s002  -NewPassword '<alnum>'
   ```

   The vault is a local, gitignored file. Seed each `yamisad-sNNN` before its
   scenario's first run ([usernames.md](usernames.md) explains why).

4. **Validate.** `test/Test-Config.ps1` from the `yuruna` folder.

## The automation model

Every scenario is **independent and reproducible**: no scenario depends on a
checkpoint VM left by another. Each scenario's `username` cascades down its
whole baseline chain, so all its VM tiers are provisioned under that scenario's
own user and password — which is exactly why chains cannot share checkpoints.

```
[1] build, once per run (user yamisad-build):
    start.guest -> amisad.build (rustup, bazelisk)
      compiles the workspace, uploads amisad-binaries.tgz to the stash
      service (durable, per-upload record), then the VM is stopped.

[2] each scenario, in order, fully cold (user yamisad-sNNN):
    start.guest -> amisad.k8s (Kubernetes + PostgreSQL + NATS)
                -> amisad.core (python3; downloads binaries from the stash,
                                deploys the 10 services)
                -> scenario run + TVP asserts
                -> VM renamed amisad.sNNN.<word>, left LIVE
    The intermediate names are consumed by the renames, so the next
    scenario's chain mints them fresh without collisions.
```

VM lifecycle: when a scenario passes, the **previous** scenario's VM is stopped
(kept on disk for inspection) and the new one stays live; when a scenario
fails, the run stops and its VM is left running for debugging.

## Run

From an **elevated** PowerShell:

```powershell
poc\build\serve-local.ps1              # lab mode: publish HEAD to the status server
pwsh poc\build\run-tests.ps1 -NoConfigGate
```

`run-tests.ps1` removes every `amisad.*` and leftover `test-*` VM (enforcing
the clean start), runs the build stage, then each scenario from its registry in
order. Green ends with `ALL SCENARIOS PASSED`. Stage logs land under
`%TEMP%\amisad-tests\`; watch live progress at `http://localhost:8080/status/`.
Expect roughly 15 min for the build plus ~20 min per scenario, all cold.

**Headless runs.** GUI keystroke injection at first login is only reliable
while a display is painting. For unattended runs, opt into the framework's
virtual display once (`[Environment]::SetEnvironmentVariable(
'YURUNA_VIRTUAL_DISPLAY','1','User')` — the driver then attaches it at run
start, as the runner's cycle path does); otherwise keep an active console/RDP
session on the host during the run.

**Repo delivery.** In lab iteration mode (current), guests fetch the repo as a
tarball of `amisad.dev` HEAD from the host status server — rerun
`poc\build\serve-local.ps1` after every commit. The production path (kept for
later) git-clones with the vault PAT in a `sensitive: true` step.

## Adding a scenario

1. Implement the guest run script under `poc/test/ubuntu.server.24/`
   (`ubuntu.server.24.workload.core.amisad.sNNN.<word>.sh`) and the sequence
   under `poc/test/gui/`. Start from the parked skeleton in
   `poc/test/gui-parked/` but rework it for the core tier — compare the s001
   pair: rename the file `...k8s.amisad.sNNN...` → `...core.amisad.sNNN...`,
   chain to `...core.amisad.baseline`, change `requiresSnapshot.id` and the
   first `loadDiskSnapshot` from `amisad.k8s` to `amisad.core` (a leftover
   `amisad.k8s` restore SUCCEEDS silently and rolls back the deployed
   cluster), drop the skeleton deploy step (the core baseline already
   deploys), point the run step at the new script, set
   `username: yamisad-sNNN`, and end with `saveDiskSnapshot` +
   `loadDiskSnapshot` of `amisad.sNNN.<word>`. Delete the parked original.
2. Seed `yamisad-sNNN` keystroke-safe in the vault (setup step 3).
3. Append the sequence + final VM name to the `$Scenarios` registry in
   `poc/build/run-tests.ps1`.
4. Update [usernames.md](usernames.md) and this file if the pattern changes.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
