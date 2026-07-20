# AmisAd POC — test automation

Full automation from a **clean machine** (no pre-built VMs): build the design
topology, then run each implemented scenario in order against it. For running
the demo by hand instead, see [demo.md](demo.md).

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
   Set-Password -Username amisad-vm-build-admin  -NewPassword '<alnum>'
   Set-Password -Username amisad-vm-core-admin   -NewPassword '<alnum>'
   Set-Password -Username amisad-vm-edge-a-admin -NewPassword '<alnum>'
   Set-Password -Username amisad-vm-edge-b-admin -NewPassword '<alnum>'
   Set-Password -Username maya  -NewPassword '<alnum>'
   Set-Password -Username elena -NewPassword '<alnum>'
   ```

   The vault is a local, gitignored file. Seed every new username before its
   first cold run ([usernames.md](usernames.md) explains why).

4. **Validate.** `test/Test-Config.ps1` from the `yuruna` folder.

## The automation model

The driver builds the design topology
([plan/design/01-overview.md](../plan/design/01-overview.md)) and runs every
scenario against the same `amisad-vm-core` — each scenario's opening restore of
the `amisad-vm-core` snapshot **is** its state reset, so scenarios stay
independent without per-scenario VMs. Hostnames are set with the framework's
`hostname` variable; each VM's admin is `<hostname>-admin`
([usernames.md](usernames.md)).

```
[1] amisad-vm-build   start.guest -> build tools -> snapshot; compile run
                      uploads amisad-binaries.tgz to the stash service; VM
                      stopped afterwards.
[2] amisad-vm-edge-a  start.guest -> demo key + IP reporter -> snapshot.
    amisad-vm-edge-b  (provisioned one at a time: first-login OCR is only
                      reliable with no other lab VM running)
[3] amisad-vm-core    start.guest -> k8s + PostgreSQL + NATS (snapshot
                      amisad-vm-core-k8s) -> binaries from the stash, deploy
                      10 services, add maya/elena -> snapshot amisad-vm-core.
[4] edge-a started; it reports its IP to the status server.
[5] scenarios in order, each: restore amisad-vm-core -> drive over SSH
    (sshWaitReady + sshFetchAndExecute; no OCR, so live edge VMs cannot
    disturb it) -> full TVP asserts. slice-runtime runs on amisad-vm-edge-a.
```

After `start.guest`'s one OCR-driven first login per VM, everything runs over
SSH with the harness key and passwordless sudo.

## Run

From an **elevated** PowerShell:

```powershell
poc\build\serve-local.ps1              # lab mode: publish HEAD to the status server
pwsh poc\build\run-tests.ps1 -NoConfigGate
```

`run-tests.ps1` removes every amisad lab VM and leftover `test-*` VM
(enforcing the clean start), generates the core→edge demo keypair if missing,
builds the topology, then runs each scenario from its registry in order. Green
ends with `ALL SCENARIOS PASSED`, leaving `amisad-vm-core` + `amisad-vm-edge-a`
live as the demo environment. Stage logs land under `%TEMP%\amisad-tests\`;
watch live progress at `http://localhost:8080/status/`. Expect ~15 min for the
build, ~15 min per edge, ~20 min for vm-core, and a few minutes per scenario.

**Headless runs.** First-login GUI keystrokes are only reliable while a display
is painting. For unattended runs, opt into the framework's virtual display once
(`[Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY','1','User')`);
otherwise keep an active console/RDP session on the host during provisioning.

**Repo delivery.** In lab iteration mode (current), guests fetch the repo as a
tarball of `amisad.dev` HEAD from the host status server — rerun
`poc\build\serve-local.ps1` after every commit. The production path (kept for
later) git-clones with the vault PAT in a `sensitive: true` step.

## Adding a scenario

1. Implement the guest run script under `poc/test/ubuntu.server.24/`
   (`ubuntu.server.24.amisad-vm-core.sNNN.<word>.sh`) and the sequence under
   `poc/test/gui/`. Start from the s001/s002 pair: chain to
   `...amisad-vm-core.deploy`, `requiresSnapshot`/`loadDiskSnapshot`
   `amisad-vm-core`, `username: amisad-vm-core-admin`,
   `hostname: amisad-vm-core`, then `sshWaitReady` + `sshFetchAndExecute` the
   script + `saveSystemDiagnostic`. (The parked skeletons under
   `poc/test/gui-parked/` predate this model — rework, don't copy: their
   `amisad.k8s` restore and skeleton deploy step must not survive.)
2. Append the sequence name to the `$Scenarios` registry in
   `poc/build/run-tests.ps1`.
3. If the scenario needs region B, start `amisad-vm-edge-b` in the driver
   (mirroring the edge-a start) — its VM is already provisioned.
4. Update [usernames.md](usernames.md) and this file if the pattern changes.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
