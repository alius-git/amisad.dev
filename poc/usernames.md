# AmisAd POC — guest VM hostnames and usernames

Guest VMs follow the design topology ([plan/design/01-overview.md](../plan/design/01-overview.md)).
Each VM's **hostname** is set with the Yuruna `hostname` sequence variable
(cascades down the chain to provisioning, like `username`), and its initial
**administrator** account is `<hostname>-admin`. Demo persona accounts are
added as **non-administrators** (`adduser`, no sudo) on the VM that hosts
their scenarios.

**Vault seeding (required once per username).** Auto-generated vault passwords
can contain characters (`@`, `^`, …) the GUI keystroke path mistypes at first
login. Seed every username keystroke-safe (letters+digits) before its first
cold run, from `c:\git\yuruna` in `pwsh`:

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
| `priya` | Priya, the platform operator | s004.failover narrative: receives the cross-party incident case; the platform-svc `curl` steps work from her account. |

All four are created by the vm-core deploy chain (`adduser --disabled-password`,
then a vault-rendered `chpasswd` in a `sensitive: true` step) and are **not**
in sudoers.

## Service accounts (not login users)

| Account | Where | Purpose |
|---------|-------|---------|
| `amisad` | PostgreSQL role on `amisad-core` | App role for ledger-svc and seller-svc (`DATABASE_URL`). INSERT+SELECT only on ledger tables — append-only is database-enforced. Fixed lab password `amisadpoc2026` (inside a URL, so alphanumeric); not vault-managed, provisioned by the db step. |
| `amisad_audit_ro` | PostgreSQL role (NOLOGIN) | Read-only ledger access reserved for audit-svc; independence is architectural. |

## Core→edge access

Scenario scripts on vm-core reach the edge VMs with a dedicated **demo
keypair** (`amisad-demo-key`), generated host-side by `run-tests.ps1` under
`test/status/handoff/` and fetched by the guests from the status server. The
edges' boot-time IP reporter posts `<hostname>.ip.txt` there too, which is how
vm-core resolves them without DNS. Lab deviation, deliberate: the handoff dir
is readable on the trusted lab LAN.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
