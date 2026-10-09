# AmisAd POC -- test automation

Full automation from a **clean machine** (no pre-built VMs): build the design
topology, then run each implemented scenario in order against it. For running
the demo by hand instead, see [demo.md](demo.md).

## Native service contract checks

From `poc/`, run `cargo build --workspace --locked`,
`cargo test --workspace --locked`, `python3 test/check_messages.py`, and
`python3 test/service_contracts.py -v`. Set `AMISAD_BIN_DIR` when the binaries
are outside `target/debug`. Tests start isolated loopback processes and stubs;
the deadline case takes about 20 seconds. They require no VM or temporary commit.

Run `python3 test/http_shutdown_contracts.py -v` for the
[shared HTTP lifecycle checks](test/http_shutdown_contracts.py). They compile a
std-only fixture in a temporary directory with `rustc` (`RUSTC` can select the
compiler; `AMISAD_LIFECYCLE_BINARY` can select a prebuilt fixture). Normal HTTP
checks run on Windows too. Unix checks require SIGTERM to stop new intake,
finish the active write and response, drop service state, and preserve the journal
across restart. Linux also checks the real PID 1 behavior in private `unshare`
namespaces; those cases skip when unprivileged namespaces are unavailable.
The services retain their request deadlines, Kubernetes termination grace, and
single-writer `Recreate` deployment policy.

To check durable recovery, initialize an **empty disposable PostgreSQL database**
with `db/schema.sql`, set `AMISAD_TEST_DATABASE_URL` to its connection URL, and run
`python3 test/service_contracts.py DurableContracts -v`. This explicit suite writes
fixture offers, instructions, orders, and refunds, then restarts the services.
Use a fresh database for each invocation; never point it at the demo database.
The regular suite uses memory stores regardless of the caller's `DATABASE_URL`.

These checks complement the VM scenarios below. They do not qualify Kubernetes,
Bazel runfiles, or the pinned container image toolchain.

## One-time setup

1. **Get the framework.** Use the OS one-liner from the Yuruna repo's
   `install/README.md` (Remote one-liners) -- it installs dependencies and
   clones the framework to `~/git/yuruna` (`%USERPROFILE%\git\yuruna` on
   Windows).

2. **Point Yuruna at AmisAd.** From the `yuruna` folder:

   ```powershell
   Copy-Item test/test.config.yml.template test/test.config.yml
   ```

   Edit `test/test.config.yml`:
   - `repositories.projectUrl`: `https://github.com/alius-git/amisad.dev.git`
     (or a local clone path) -- sequences are discovered under `poc/test/`.
   - `repositories.ghToken`: a GitHub PAT with read access (host-side clone).
   - `guestSequence`: trim to `- guest.ubuntu.server.24`.

3. **Seed the vault.** From the `yuruna` folder in `pwsh`:

   ```powershell
   Import-Module ./test/extension/authentication/default.psm1
   # Guest PAT for the production clone path (lab mode does not use it):
   Set-UserVaultKey -LogicalUser amisad-pat -VaultKey amisad-pat
   Set-Password -Username amisad-pat -NewPassword '<the PAT>'
   # One keystroke-safe (alphanumeric) password per username -- see usernames.md:
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
   This project ships **no stash address** -- a lab's stash address is that
   lab's, and a literal here would go stale the first time the service moved.
   Any one of these is enough:

   - run one on this host: `test/service/Start-StashServiceVM.ps1` from the `yuruna`
     folder;
   - join a pool that runs one -- the service announces itself to the
     pool-aggregator and this host reads the address back (nothing to
     configure beyond the caching-proxy-service this host already uses);
   - state it: `$env:YURUNA_STASH_SERVICE_HOST = '<address>'`, or
     `pwsh test/Initialize-Lab.ps1 -StashServiceHost '<address>'` from this
     repository.

   The preflight probes `/healthz` on each candidate before anything long
   starts, publishes the one that answered for the rest of the cycle, and
   **stops the run immediately** when none does -- it never guesses an address.

5. **Validate.** `test/Test-Config.ps1` from the `yuruna` folder.

## The automation model

The driver builds the design topology
([plan/design/01-overview.md](../plan/design/01-overview.md)) and runs every
scenario against the same `amisad-core` -- each scenario's opening restore of
the `amisad-core` snapshot **is** its state reset, so scenarios stay
independent without per-scenario VMs. Hostnames are set with the framework's
`hostname` variable; each VM's admin is `<hostname>-admin`
([usernames.md](usernames.md)).

```
[0] cleanup        remove every amisad lab VM (current and legacy names)
                      and any leftover test-* VMs with their storage dirs;
                      delete a demo private key found in the status
                      service's served tree; resolve the
                      stash service (pinned or discovered), verify /healthz,
                      and publish the address -- no stash, no run.
[1] amisad-build   start.guest -> build tools -> snapshot; compile run
                      uploads amisad-<arch>-binaries.tgz to the stash service
                      and records its SHA-256 for the deploy to verify;
                      VM stopped afterwards.
[2] amisad-edge-a  start.guest -> IP reporter -> snapshot.
    amisad-edge-b  (provisioned one at a time: first-login OCR is only
                      reliable with no other lab VM running)
[3] amisad-core    start.guest -> k8s + PostgreSQL + NATS (snapshot
                      amisad-core-k8s) -> binaries from the stash, deploy
                      10 services (ledger+seller on PostgreSQL), add
                      maya/elena/tom/priya/marcel/kai/pat/alex/sam/dana/ingrid
                      and generate the core->edge demo keypair INSIDE this
                      VM -> snapshot amisad-core.
[4] both edges started; each reports its IP to the status service.
[4b] the PUBLIC half of amisad-core's demo key is written into both edges'
                      authorized_keys over the harness SSH channel, and
                      amisad-core's login to each is proved.
[5] scenarios in order, each: restore amisad-core -> drive over SSH
    (sshWaitReady + sshFetchAndExecute; no OCR, so live edge VMs cannot
    disturb it) -> full TVP asserts. slice-runtime runs on amisad-edge-a
    (s004 also on amisad-edge-b, with attested region identity).
```

After `start.guest`'s one OCR-driven first login per VM, everything runs over
SSH with the harness key and passwordless sudo.

Both host entrypoints use the same edge admission helper: start both edges before
waiting and require a fresh, valid IP report from each. A missing report or failed
start stops the run before scenarios. See the
[host orchestration constraints](https://yuruna.link/42010605-0006) and
[download trust boundary](https://yuruna.link/42010605-0008).

## Run

From `pwsh` -- on a Hyper-V host it must be **elevated** (KVM and UTM drive the
hypervisor as the invoking user, so they need no elevation; the driver asserts
whichever applies to the detected host before it touches a VM):

```powershell
pwsh poc/build/run-tests.ps1 -NoConfigGate
```

`run-tests.ps1` removes every amisad lab VM and leftover `test-*` VM
(enforcing the clean start), deletes a demo key found in the status service's
served tree, resolves the stash service and stops at once if
none answers (see [one-time setup](#one-time-setup) step 4), builds the
topology, hands the edges amisad-core's public demo key (see
[usernames.md](usernames.md#core-edge-access)), then runs each scenario from its
registry in order. Green ends with `ALL SCENARIOS PASSED`,
leaving `amisad-core` and both edge VMs live as the demo environment. Stage
logs land under `<temp>/amisad-tests/` (override with `-LogDir`); watch live progress at
`http://localhost:8080/status/`. Expect ~15 min for the build, ~15 min per
edge, ~20 min for vm-core, and a few minutes per scenario.

**Headless runs.** First-login GUI keystrokes are only reliable while a display
is painting. For unattended runs, opt into the framework's virtual display once
(`[Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY','1','User')`);
otherwise keep an active console/RDP session on the host during provisioning.

**Repo delivery.** Guests fetch `/yuruna-project-archive.tar.gz` from the host
status service. It archives HEAD of the framework's `<RepoRoot>/project` clone,
with `poc/`, `test/`, and the rest of the project at the archive root. The
runner populates that clone from `repositories.projectUrl`; uncommitted edits
are excluded. Both the [compile script](test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh)
and the [deploy script](test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh)
use this endpoint, and verify what it returns before extracting it (see
[Verified nested downloads](#verified-nested-downloads)). The production path (kept for later) git-clones with the
vault PAT in a `sensitive: true` step.

**Durable stores.** The db step provisions the `amisad` database with the app
role `amisad` (fixed lab password `amisadpoc2026` -- it rides inside a URL, so
alphanumeric on purpose), opens `listen_addresses`/pg_hba to the pod and node
networks, and grants SELECT and INSERT on the three append-only ledger tables,
with no UPDATE or DELETE grant. It also grants SELECT, INSERT, and UPDATE on
`ledger.settlement_instructions`. The same
app role receives SELECT, INSERT, and UPDATE on `seller.offers`, `seller.orders`,
and `seller.inventory`; inventory access is required during seller startup as
well as during stock updates.
`deploy.sh` passes `DATABASE_URL` (node
IP:5432) to ledger-svc and seller-svc via the `databaseUrl` helm value; writes
go to PostgreSQL first, and pods reload state on start. s001 asserts the rows
landed and that a `kubectl rollout restart` reloads verifying chains and the
settled order; s002 asserts the booked appointment row; s003 asserts the
consent chain's six grant/revoke/re-grant rows; s004 asserts all twelve
attestation rows; s005 the boosted 5-way settlement; s006 the mandate
grant+revoke consent rows; s007 the delta-zeroed offer leaving the catalog;
s008 the compensating adjustment entries + disclosure grant; s010 the
independent four-dimension certification and tamper localization. An empty
`databaseUrl` (the chart default) keeps a service in-memory -- how `cargo test`
and skeleton services run.

Existing `amisad-core-k8s` and `amisad-core` snapshots created before the inventory
grant must be rebuilt or repaired before reuse. The normal end-to-end cycle
removes and rebuilds these VMs automatically. For a retained lab, apply the current
`db/schema.sql` as the database administrator, then run this in the `amisad`
database. Recapture the repaired infrastructure snapshot and rebuild the deployed
`amisad-core` snapshot from it; for a running deployed VM, restart seller after
applying the grant:

```sql
GRANT SELECT, INSERT, UPDATE ON seller.inventory TO amisad;
```

## Verified nested downloads

The framework verifies the script a sequence launches against a SHA-256 the host
types into the launch command, over SSH, never against anything the download
itself carries. That protects the launched script and nothing it fetches
afterwards. The guest scripts here fetch more -- a project tarball they extract and
build, a SQL file they run as the `postgres` superuser, a binaries tarball they
turn into images that run as root -- over the status and stash services' plain HTTP, where
whatever answers the request decides the bytes. So every such input is checked
against a SHA-256 carried by the **same launch command** (the `command:` of the
`sshFetchAndExecute` step), computed on the host at step time, and **before** it
is extracted, installed or executed. The digest is the trust boundary; the status
listener offers HTTP only, so there is no transport to prefer.

| Input | Script | Variable in the launch command | Where the host gets it |
| --- | --- | --- | --- |
| Project tarball | compile, deploy | `AMISAD_PROJECT_ARCHIVE_SHA256` | `${ext:digest.GetArchiveSha256(project)}`: the status service is asked for the tarball over loopback and the bytes it answers are hashed. |
| `poc/db/schema.sql` | db | `AMISAD_SCHEMA_SHA256` | `${ext:digest.GetFileSha256(project/poc/db/schema.sql)}`: the file the service serves. |
| Stash binaries tarball | deploy | `AMISAD_BINARIES_SHA256` | `${ext:digest.GetPublishedSha256(amisad-binaries)}`: right after the build uploads, the compile sequence's `callExtension` step asks the **build VM** for the SHA-256 of the file it built, over the harness SSH channel. |

Each script verifies, deletes the download on a mismatch, and fails closed with
exit 7 and a message naming the variable when the digest is **absent** -- an empty
value means the host could not compute it (its warning is in the host log) or the
script was started by hand. A hand run that has no digest can set
`AMISAD_ALLOW_UNVERIFIED=1`: the download is then used as it arrived and a warning
banner says so. No sequence sets it, a wrong digest is still refused, and a
malformed one is refused even with it set. Downloads land in a private directory
(mode 0700), not loose in `/tmp`, and the schema reaches `psql` on stdin, so
another local user cannot swap a file between its check and its use.

**The archive digest is of the exact bytes the service serves.** The tarball is
cut on demand from the project clone's HEAD, with two sidecars carrying the origin
and the commit. A re-cut of one commit is byte-identical -- tar entries carry the
commit time and fixed ownership, and the gzip header has no timestamp, which the
framework's archive suite holds -- and the service also keeps what it cut per
commit, so the download that follows the hash gets the bytes that were hashed. If
the clone's HEAD moves between the two (a `git pull` in `project/` mid-step), the
guest refuses the download; re-run the step.

**The binaries tarball is selected by digest, not by recency.** The stash is shared
by the whole lab, so another pass or host can upload the same label after this
pass's build. The deploy script looks back through the ten newest uploads for the
one whose SHA-256 is the build's, so an upload altered or replaced on its way
through the stash is refused, and a busy lab does not hand one pass another pass's
binaries.

**Upstream releases are pinned, not trusted by transport.** `rustup-init` (a named
release, instead of piping the rustup.rs installer into `sh`), `bazelisk` (a named
release, instead of whatever `latest` is on the day) and the NATS server tarball
are downloaded from their publishers and then executed or installed as root. Each is
checked against the publisher's own SHA-256, pinned in the script that fetches it:
the `.sha256` beside each `rustup-init`, the digest GitHub shows on each bazelisk
release asset, and the `SHA256SUMS` of the NATS release. The pins live in a script
the framework verified against the digest the host typed into the launch command,
so they are exactly as trustworthy as the script. To bump a version, change it and
its digests together.

`test/download_contracts.py` and `test/nats_installer_contracts.py` hold all of
this: the helper copies stay identical, each script verifies before it extracts, the
launch commands carry every variable their script reads, and a download that does
not match is refused and removed.

**Deliberately not covered:**

- `apt-get install`, `cargo` (with the committed `Cargo.lock`) and `npm` (with
  `package-lock.json`): the package managers verify signed indexes or lockfile
  hashes themselves.
- Bazel's module and toolchain archives: Bazel verifies them against the
  registry's integrity hashes.
- The container base images pulled during `docker build` (`rust:*-slim` and the
  distroless runtime base): referenced by tag, not by digest. The images that run
  the ten services are built locally from the verified binaries.

## Project archive helper

[build/Publish-ProjectArchive.ps1](build/Publish-ProjectArchive.ps1) publishes this checkout's committed
HEAD to `<yuruna-root>/project-poc.tar.gz`, served at
`/yuruna-repo/project-poc.tar.gz`. Republish after a commit when using this
manual archive; it excludes uncommitted changes. The active guest scripts use
the project-archive endpoint described above, so normal test and demo runs
do not need this helper.

## Snapshot page-cache flush

Guest steps that end in a snapshot finish with `sync`. The host freezes the
VM's disk for the snapshot as soon as the step exits, and it does not ask the
guest to write back first; whatever is still in the page cache at that
instant is not in the snapshot. The failure is silent and deferred --
the file stays readable for the rest of the SSH session and is missing only
once the snapshot is restored -- so it surfaces far from its cause, in
whichever later sequence first needs the lost write: a dropped tool is a bare
"command not found", a dropped service binary or unit file means a restored
VM whose dependents start against a service that is not there, and a dropped
`/etc/shadow` rewrite leaves users whose logins accept only their old
passwords. Large, recently written files are lost first: an 8 MB binary
installed as a script's last action has not aged past the filesystem's
writeback interval, while the small files written seconds earlier have. The
guest scripts flush at the end of their own runs; a sequence whose last write
rides an inline `sshExec` (which has no such tail) adds an explicit `sync`
step before the snapshot instead.

## Stash artifact naming

The compile step packs the release binaries as `amisad-<arch>-binaries.tgz`
(`<arch>` from `uname -m`) and the deploy step downloads only the label
matching its own architecture. The stash is one shared service for the whole
lab, so the artifact name has to say which machine code it holds: were every
host to upload under one label, the newest upload would answer every request,
and a guest handed another architecture's build gets binaries its kernel
cannot run -- every pod then dies with "exec format error" and the deploy only
reports a rollout timeout, far from the cause.

The architecture sits in the middle of the name on purpose. The stash matches
filenames by substring, so a host still asking for the bare `amisad-binaries`
label would keep matching a trailing `amisad-binaries-<arch>` form and stay
exposed; it cannot match `amisad-<arch>-binaries`. Hosts adopt the
architecture-qualified label at their own pace without ever being handed a
foreign build.

## Adding a scenario

1. Implement the guest run script under `poc/test/ubuntu.server.24/`
   (`ubuntu.server.24.amisad-core.sNNN.<word>.sh`) and the sequence under
   `poc/test/`. Start from the s001-s004 set: chain to
   `...amisad-core.deploy`, `requiresSnapshot`/`loadDiskSnapshot`
   `amisad-core`, `username: amisad-core-admin`, `hostname: amisad-core`.
   `component:` is a single `retry` block -- `loadDiskSnapshot`,
   `sshWaitReady`, then `sshFetchAndExecute` of
   `...amisad-core.ready.sh`, which restarts the deployed services onto pods
   that exist now and waits for every NodePort to answer. `workload:` is
   `sshFetchAndExecute` of the scenario script plus `saveSystemDiagnostic`,
   outside the retry on purpose: putting the cluster in position is
   idempotent and worth a second attempt, while a scenario that passes only
   on a replay is reporting a defect. The scenario script therefore assumes a
   live cluster and starts at its first call -- no readiness gate of its own.
2. Append the sequence name to the `$Scenarios` registry in
   `poc/build/run-tests.ps1`.
3. Both edges are started by the driver and stay live; resolve either from
   its status-server IP report (see the s004 script).
4. Update [usernames.md](usernames.md) and this file if the pattern changes.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.

## Focused recovery and packaging checks

After `cargo build --workspace --locked`, run `python3 test/service_contracts.py`
and `python3 test/check_messages.py`. For durable inventory and settlement recovery,
apply `db/schema.sql` to a disposable PostgreSQL database, set
`AMISAD_TEST_DATABASE_URL`, and run `python3 test/service_contracts.py DurableContracts`.
These tests create records and restart their own local service processes.

`python3 test/build_contracts.py`, `python3 test/nats_installer_contracts.py`, and
`pwsh test/host_contracts.ps1` use disposable paths and native command fixtures;
they do not modify the host firewall, install system services, or deploy VMs.
Run `flutter test` and `flutter analyze` in `components/apps/buyer-flutter` for
request-deadline, navigation/disposal, and stale-response checks.

Scenario HTTP diagnostics and edge lookup are shared in `test/amisad-scenario.sh`,
loaded from the extracted project archive. `build/Publish-ProjectArchive.ps1`
is the canonical archive command; `build/serve-local.ps1` forwards for compatibility.
Seller and ledger compile the database-specific `amisad-common/src/database.rs`
module directly; the common library itself remains std-only. SQL errors return
503 without terminating a live connection; a closed connection exits for restart.
`test/database_policy_contracts.py` verifies both against a disposable PostgreSQL
database selected by `DATABASE_POLICY_URL` (never use an existing lab database).
Run it with an administrative connection to a disposable PostgreSQL cluster and
`PSQL` pointing to `psql` if it is outside PATH. Its provisioning regression applies
`db/schema.sql` and the actual grant block from the guest db script in a rolled-back
transaction, then exercises inventory reads and writes as the non-superuser
`amisad` role and verifies that ledger UPDATE/DELETE remain forbidden. Run that
check alone with:

```bash
python3 test/database_policy_contracts.py DatabasePolicy.test_provisioned_inventory_permissions -v
```

The SPA provides unknown-route recovery in English, Portuguese, Chinese, and
Hebrew. Translations are machine drafts with source hashes in
`messages.provenance.json`; `python3 test/check_messages.py` checks completeness,
unused keys, and staleness. `node test/low_browser_contracts.cjs` tests the built SPA
with Chrome; `PLAYWRIGHT_MODULE` and `CHROME_PATH` can override local tool paths.
