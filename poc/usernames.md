# AmisAd POC — guest VM usernames

Guest usernames are **per scenario** (plus one for the build VM). The username
is set as `variables.username` on the scenario's top-level sequence and
cascades down its entire baseline chain (start.guest → amisad.k8s →
amisad.core → scenario), so every VM tier of a scenario's chain — including the
first baseline VM — is provisioned under that scenario's own user and password.

**Why per-scenario.** A Yuruna disk snapshot bakes in exactly one guest
account, and the base Ubuntu image forces a password rotation on first login —
so two chains sharing a username (or a checkpoint) fight over one auth-vault
entry. Per-scenario users make every scenario chain fully independent: no
scenario depends on a checkpoint VM left by another, and each run is
reproducible from a clean machine (see [test.md](test.md)).

**Vault seeding (required once per new username).** Auto-generated vault
passwords can contain characters (`@`, `^`, …) the GUI keystroke path mistypes,
which fails first login. Before a username's first cold run, seed it
keystroke-safe (letters+digits only), from `c:\git\yuruna` in pwsh:

```powershell
Import-Module ./test/extension/authentication/default.psm1
Set-Password -Username <name> -NewPassword '<alphanumeric>'
```

## Usernames

| Username | Owner | Function |
|----------|-------|----------|
| `yamisad-build` | `amisad.build` VM | Rust toolchain only; compiles the workspace and uploads the binaries tarball to the stash service. One build per test run; every scenario downloads the same artifact. |
| `yamisad-s001` | s001.fulfillment chain → `amisad.s001.fulfillment` VM | Intent-driven edge match + automated fulfillment. |
| `yamisad-s002` | s002.fitting chain → `amisad.s002.fitting` VM | Considered purchase, constraint fidelity, in-person booking. |
| `yamisad-s003` … `yamisad-s010` | s003.silence … s010.certification chains | One per scenario, same pattern, as each is implemented. |

Intermediate chain tiers (`amisad.k8s`, `amisad.core`) are transient: each
scenario's chain mints them under its own user and consumes them via the
snapshot renames, ending in the scenario's named VM. If a scenario's topology
later adds VMs (e.g. the design's edge VMs), they take the owning scenario's
username with a suffix (`yamisad-s004-edge-b`).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
