# AmisAd POC -- guest VM hostnames and usernames

Guest VMs follow the design topology ([plan/design/01-overview.md](../plan/design/01-overview.md)).
Each VM's **hostname** is set with the Yuruna `hostname` sequence variable
(cascades down the chain to provisioning, like `username`), and its initial
**administrator** account is `<hostname>-admin`. Demo persona accounts are
added as **non-administrators** (`adduser`, no sudo) on the VM that hosts
their scenarios.

**Vault seeding (required once per username).** Auto-generated vault passwords
can contain characters (`@`, `^`, ...) the GUI keystroke path mistypes at first
login. Seed every username keystroke-safe (letters+digits) before its first
cold run, from the Yuruna checkout root in `pwsh`:

```powershell
Import-Module ./test/extension/authentication/default.psm1
Set-Password -Username <name> -NewPassword '<alphanumeric>'
```

## VMs and administrators

| VM / hostname | Design node | Administrator | Function |
|---------------|-------------|---------------|----------|
| `amisad-build` | build box (lab infra) | `amisad-build-admin` | Rust toolchain only; compiles the workspace and uploads the binaries tarball to the stash service. Stopped after the build stage. |
| `amisad-core` | **vm-core** | `amisad-core-admin` | Kubernetes + PostgreSQL + NATS + the ten deployed services. Scenarios run here over SSH; each restores the `amisad-core` snapshot as its state reset. |
| `amisad-edge-a` | **vm-edge-a** (region A) | `amisad-edge-a-admin` | Stateless slice VM; `slice-runtime` is delivered per scenario run over SSH from vm-core. Live during scenarios/demos. |
| `amisad-edge-b` | **vm-edge-b** (region B) | `amisad-edge-b-admin` | Same, region B; live during scenarios/demos since `s004.failover` (the sovereignty scenario needs a roomier non-compliant region to exclude). |

The intermediate snapshot `amisad-core-k8s` is transient (consumed by the
deploy tier's rename). Admins get passwordless sudo and the harness SSH key at
provisioning; after `start.guest`'s one OCR-driven first login, everything runs
over SSH.

## Demo users (non-administrators, on `amisad-core`)

| Username | Persona | Purpose |
|----------|---------|---------|
| `maya` | Maya, the buyer | Console/SSH login persona for the demo narrative; API (`curl`) steps work from her account. `buyer-client` itself runs from the admin account (the binaries live under the admin's 0750 home). |
| `elena` | Elena, the seller | Console/SSH login persona for the seller narrative; the order-board `curl` steps work from her account. |
| `tom` | Tom, the carrier/resource operator | s004.failover narrative: allocation policy, incident queue, escalation; the resource-svc `curl` steps work from his account. |
| `priya` | Priya, the platform operator | s004.failover + s007.inventory narrative: cross-party incident case; participant registry verification. |
| `marcel` | Marcel, the ad agency | s005.attribution narrative: campaign, creative brief, attribution report; the ads-svc `curl` steps work from his account. |
| `kai` | Kai, the creative | s005.attribution narrative: accepts the brief, produces the asset, performance view. |
| `pat` | Pat, the delegate | s006.mandate narrative: acts under Maya's scoped mandate in the delegate workspace. |
| `alex` | Alex, the integration partner | s007.inventory narrative: builds/certifies the connector; the connect-svc `curl` steps work from his account. |
| `sam` | Sam, the support agent | s008.mediation narrative: works the support case from metadata; requests the scoped disclosure. |
| `dana` | Dana, the demand analyst | s009.suppression narrative: reads the insights workbench, publishes the demand outlook. |
| `ingrid` | Ingrid, the trust auditor | s010.certification narrative: runs the independent certification in audit-svc. |

All eleven are created by the vm-core deploy chain (`adduser --disabled-password`,
then a vault-rendered `chpasswd` in a `sensitive: true` step) and are **not**
in sudoers.

## Service accounts (not login users)

| Account | Where | Purpose |
|---------|-------|---------|
| `amisad` | PostgreSQL role on `amisad-core` | App role for ledger-svc and seller-svc (`DATABASE_URL`). INSERT+SELECT only on ledger tables -- append-only is database-enforced. Fixed lab password `amisadpoc2026` (inside a URL, so alphanumeric); not vault-managed, provisioned by the db step. |
| `amisad_audit_ro` | PostgreSQL role (NOLOGIN) | Read-only ledger access reserved for audit-svc; independence is architectural. |

## Core->edge access

Scenario scripts on vm-core reach the edge VMs with a dedicated **demo
keypair** (`~/.ssh/amisad-demo-key` in the `amisad-core-admin` home). The pair is
generated **inside vm-core**, by the users step of the deploy chain (ed25519,
empty passphrase; a key that already parses is kept), and **the private key never
leaves that VM**. Once both edges are live, the lab driver
(`test/Initialize-Lab.ps1` stage 6, `poc/build/run-tests.ps1` stage 4b) reads the
*public* half out of vm-core and writes it into each edge's `authorized_keys`,
both over the harness SSH channel -- the one every other host-to-guest action
uses -- and then proves the login from vm-core. Each edge keeps exactly one entry
ending in `amisad-demo`: a re-run replaces it instead of appending, so a rotated
key invalidates the previous one. The edges cannot be given the key when they are
provisioned, because they are built before vm-core exists.

**Why the status service is not the channel.** The status service answers every
machine that can reach its port, so a file it serves is readable by the whole LAN:
a design that parks the private key where guests can download it publishes the
key, and a "trusted lab LAN" does not bound who can read a served file. So nothing
here creates, copies or serves a private key under a directory the status service
serves (`test/status`, its `runtime/` and `log/` mounts, or the
checkout it serves as `yuruna-repo/`), and the framework's listener also refuses
private-key file names wherever they sit. The public key is not secret and travels over SSH. The edges' IP reports
(`<hostname>.ip.txt` under the status server's `log/handoff/`, which is how vm-core
resolves them without DNS) are also not secret and travel by
that route.

**Rotation (operator).** A host that ran an older version of this lab generated
the pair under `test/status/handoff/` and had the guests download both halves
from the status service, so it may have served the private key to the LAN: treat
it as exposed. `Initialize-Lab.ps1` and
`run-tests.ps1` delete `test/status/handoff/amisad-demo-key` and its `.pub` when they
find them and say so, and every VM built from then on trusts a new key. A
long-lived VM built earlier still trusts the old one: rebuild it, or remove the
`authorized_keys` line ending in `amisad-demo`
(`sed -i '/ amisad-demo$/d' ~/.ssh/authorized_keys`) and let the driver add the new
one. Restart the host's status service too, so a listener started before the
framework refused key names is not left running.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
