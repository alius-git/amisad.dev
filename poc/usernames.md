# AmisAd POC — guest VM usernames

Each **VM** in the demo lab gets its **own** guest-OS username (not one per
scenario). The username is set as `variables.username` on the *top-level*
sequence for that VM and cascades down its whole baseline chain (start.guest →
… → the VM's snapshot). Scenarios that share a VM share its username.

**Why per-VM, not per-scenario.** The base Ubuntu image expires the account
password on first login. Two VMs provisioned from that image under the *same*
username fight over one auth-vault entry — one VM's forced rotation invalidates
what the next expects. A distinct username per VM gives each its own vault entry
and removes the collision. A Yuruna disk snapshot also bakes in exactly one
guest account, so a snapshot lineage (e.g. `amisad.k8s` → `amisad.core`) can
carry only one username; two lineages that must differ must not share a
snapshot id (this is why the build VM is decoupled from `amisad.k8s`).

**Vault seeding.** A new username self-seeds a random password on first cold
provision, but auto-generated passwords can contain characters (`@`, `^`, …)
that the GUI keystroke path mistypes. Seed a keystroke-safe **alphanumeric**
password once per new username before its first cold run:
`Set-Password -Username <name> -NewPassword '<alnum>'` (Yuruna auth extension).

## Active VMs (implemented)

| VM (Hyper-V name) | Design node | Username | Function |
|-------------------|-------------|----------|----------|
| `amisad.build` | dev/build box | `yamisad-build` | Rust toolchain only. Compiles the workspace (`cargo build --release`) and uploads the binaries tarball to the stash service. No Kubernetes. |
| `amisad.core` | **vm-core** | `yamisad-core` | Minimal Ubuntu + Kubernetes (kubeadm) + PostgreSQL + NATS + `python3`. Downloads the prebuilt binaries, builds thin images, deploys the ten services, and runs the vm-core scenarios (`s001.fulfillment`, `s002.fitting`, …). |

`amisad.k8s` is the infrastructure baseline snapshot that `amisad.core` is built
on; it shares the `yamisad-core` lineage.

## Planned VMs (design topology, not yet implemented)

| VM | Design node | Username | Function |
|----|-------------|----------|----------|
| `amisad.edge-a` | **vm-edge-a** | `yamisad-edge-a` | Stateless slice VM — runs only `slice-runtime` for region/jurisdiction A. (Today `slice-runtime` runs on `amisad.core` in single-VM degraded mode.) |
| `amisad.edge-b` | **vm-edge-b** | `yamisad-edge-b` | Second slice VM for region B — needed by `s004.failover` (jurisdiction choice) and `s009.suppression` (above/below anonymity threshold). |
| *(mobile device)* | Test mobile device | — | Side-loaded Flutter buyer app; a physical/emulated device, not a Yuruna guest, so no lab username. |

## Reserved for future scenario/application-focused VMs

If later scenarios warrant isolating a single application onto its own VM (for
demo clarity), follow the same per-VM rule with these names:
`yamisad-buyer`, `yamisad-seller`, `yamisad-ads`, `yamisad-audit`,
`yamisad-insights`, `yamisad-platform`, `yamisad-connect`. Until then, those
applications run as services on `amisad.core` under `yamisad-core`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
