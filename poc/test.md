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
     (or a local clone path) — sequences are discovered under `poc/test/`.
   - `repositories.GH_TOKEN`: a GitHub PAT with read access (host-side clone).
   - `guestSequence`: trim to `- guest.ubuntu.server.24`.

3. **Seed the vault.** From the `yuruna` folder in `pwsh`:

   ```powershell
   Import-Module ./test/extension/authentication/default.psm1
   # Guest PAT for the production clone path (lab mode does not use it):
   Set-UserVaultKey -LogicalUser amisad-pat -VaultKey amisad-pat
   Set-Password -Username amisad-pat -NewPassword '<the PAT>'
   # One keystroke-safe (alphanumeric) password per username — see usernames.md:
   Set-Password -Username amisad-build-admin  -NewPassword '<alnum>'
   Set-Password -Username amisad-core-admin   -NewPassword '<alnum>'
   Set-Password -Username amisad-edge-a-admin -NewPassword '<alnum>'
   Set-Password -Username amisad-edge-b-admin -NewPassword '<alnum>'
   Set-Password -Username maya  -NewPassword '<alnum>'
   Set-Password -Username elena -NewPassword '<alnum>'
   Set-Password -Username tom   -NewPassword '<alnum>'
   Set-Password -Username priya -NewPassword '<alnum>'
   Set-Password -Username marcel -NewPassword '<alnum>'
   Set-Password -Username kai    -NewPassword '<alnum>'
   Set-Password -Username pat    -NewPassword '<alnum>'
   Set-Password -Username alex   -NewPassword '<alnum>'
   Set-Password -Username sam    -NewPassword '<alnum>'
   Set-Password -Username dana   -NewPassword '<alnum>'
   Set-Password -Username ingrid -NewPassword '<alnum>'
   ```

   The vault is a local, gitignored file. Seed every new username before its
   first cold run ([usernames.md](usernames.md) explains why).

4. **Provide a stash service.** `amisad-build` uploads its binaries to it and
   `amisad-core` downloads them, so a run without one has nothing to deploy.
   This project ships **no stash address** — a lab's stash address is that
   lab's, and a literal here would go stale the first time the service moved.
   Any one of these is enough:

   - run one on this host: `test/Start-StashServiceVM.ps1` from the `yuruna` folder;
   - join a pool that runs one — the service announces itself to the
     pool-aggregator and this host reads the address back (nothing to
     configure beyond the caching proxy you already point at);
   - state it: `$env:YURUNA_STASH_SERVICE_HOST = '<address>'`, or
     `pwsh test/Initialize-Lab.ps1 -StashServiceHost '<address>'`.

   The pre-flight probes `/healthz` on each candidate before anything long
   starts, publishes the one that answered for the rest of the cycle, and
   **stops the run immediately** when none does — it never guesses an address.

5. **Validate.** `test/Test-Config.ps1` from the `yuruna` folder.

## The automation model

The driver builds the design topology
([plan/design/01-overview.md](../plan/design/01-overview.md)) and runs every
scenario against the same `amisad-core` — each scenario's opening restore of
the `amisad-core` snapshot **is** its state reset, so scenarios stay
independent without per-scenario VMs. Hostnames are set with the framework's
`hostname` variable; each VM's admin is `<hostname>-admin`
([usernames.md](usernames.md)).

```
[0] cleanup        remove every amisad lab VM (old and new naming) and any
                      leftover test-* VMs with their storage dirs; ensure the
                      core->edge demo keypair exists; resolve the stash
                      service (pinned or discovered), verify /healthz, and
                      publish the address -- no stash, no run.
[1] amisad-build   start.guest -> build tools -> snapshot; compile run
                      uploads amisad-binaries.tgz to the stash service; VM
                      stopped afterwards.
[2] amisad-edge-a  start.guest -> demo key + IP reporter -> snapshot.
    amisad-edge-b  (provisioned one at a time: first-login OCR is only
                      reliable with no other lab VM running)
[3] amisad-core    start.guest -> k8s + PostgreSQL + NATS (snapshot
                      amisad-core-k8s) -> binaries from the stash, deploy
                      10 services (ledger+seller on PostgreSQL), add
                      maya/elena/tom/priya/marcel/kai/pat/alex/sam/dana/ingrid -> snapshot
                      amisad-core.
[4] both edges started; each reports its IP to the status service.
[5] scenarios in order, each: restore amisad-core -> drive over SSH
    (sshWaitReady + sshFetchAndExecute; no OCR, so live edge VMs cannot
    disturb it) -> full TVP asserts. slice-runtime runs on amisad-edge-a
    (s004 also on amisad-edge-b, with attested region identity).
```

After `start.guest`'s one OCR-driven first login per VM, everything runs over
SSH with the harness key and passwordless sudo.

## Run

From an **elevated** PowerShell:

```powershell
poc\build\serve-local.ps1              # lab mode: publish HEAD to the status service
pwsh poc\build\run-tests.ps1 -NoConfigGate
```

`run-tests.ps1` removes every amisad lab VM and leftover `test-*` VM
(enforcing the clean start), generates the core→edge demo keypair if missing,
resolves the stash service and stops at once if none answers (see
[one-time setup](#one-time-setup) step 4), builds the topology, then runs each
scenario from its registry in order. Green
ends with `ALL SCENARIOS PASSED`, leaving `amisad-core` and both edge VMs
live as the demo environment. Stage logs land under `%TEMP%\amisad-tests\`;
watch live progress at `http://localhost:8080/status/`. Expect ~15 min for the
build, ~15 min per edge, ~20 min for vm-core, and a few minutes per scenario.

**Headless runs.** First-login GUI keystrokes are only reliable while a display
is painting. For unattended runs, opt into the framework's virtual display once
(`[Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY','1','User')`);
otherwise keep an active console/RDP session on the host during provisioning.

**Repo delivery.** In lab iteration mode (current), guests fetch the repo as a
tarball of `amisad.dev` HEAD from the host status service — rerun
`poc\build\serve-local.ps1` after every commit. The production path (kept for
later) git-clones with the vault PAT in a `sensitive: true` step.

**Durable stores.** The db step provisions the `amisad` database with the app
role `amisad` (fixed lab password `amisadpoc2026` — it rides inside a URL, so
alphanumeric on purpose), opens `listen_addresses`/pg_hba to the pod and node
networks, and grants the role INSERT+SELECT only on ledger tables: append-only
is enforced by the database itself. `deploy.sh` passes `DATABASE_URL` (node
IP:5432) to ledger-svc and seller-svc via the `databaseUrl` helm value; writes
go to PostgreSQL first, and pods reload state on start. s001 asserts the rows
landed and that a `kubectl rollout restart` reloads verifying chains and the
settled order; s002 asserts the booked appointment row; s003 asserts the
consent chain's six grant/revoke/re-grant rows; s004 asserts all twelve
attestation rows; s005 the boosted 5-way settlement; s006 the mandate
grant+revoke consent rows; s007 the delta-zeroed offer leaving the catalog;
s008 the compensating adjustment entries + disclosure grant; s010 the
independent four-dimension certification and tamper localization. Empty `databaseUrl` (the
chart default) keeps a service in-memory — which is how `cargo test` and
skeleton services run.

## Adding a scenario

1. Implement the guest run script under `poc/test/ubuntu.server.24/`
   (`ubuntu.server.24.amisad-core.sNNN.<word>.sh`) and the sequence under
   `poc/test/`. Start from the s001–s004 set: chain to
   `...amisad-core.deploy`, `requiresSnapshot`/`loadDiskSnapshot`
   `amisad-core`, `username: amisad-core-admin`,
   `hostname: amisad-core`, then `sshWaitReady` + `sshFetchAndExecute` the
   script + `saveSystemDiagnostic`.
2. Append the sequence name to the `$Scenarios` registry in
   `poc/build/run-tests.ps1`.
3. Both edges are started by the driver and stay live; resolve either from
   its status-server IP report (see the s004 script).
4. Update [usernames.md](usernames.md) and this file if the pattern changes.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
