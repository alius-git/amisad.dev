# Changelog

Notable changes to amisad.dev. This repository holds the demo and
proof-of-concept material the Yuruna framework deploys as a project; the
framework's own history lives in
[yuruna/CHANGELOG.md](https://github.com/alissonsol/yuruna/blob/main/CHANGELOG.md).

Versions track the framework release the material was last exercised against,
not an independent release line -- the POC is only meaningful paired with a
framework that can deploy it.

## Unreleased

- The core->edge demo SSH key is generated inside vm-core and its private half
  never leaves that VM. Earlier versions generated the pair on the host under the
  status service's served `handoff/` directory and had the guests download it, so
  anything that could reach the status port could read the private key. The lab
  drivers now delete a key left there and hand the edges only the public half over
  the harness SSH channel, replacing any older `amisad-demo` entry. Treat a key an
  earlier run created as exposed: rebuild a long-lived VM that trusts it, or remove
  the `authorized_keys` line ending in `amisad-demo`. See `poc/usernames.md`.
- Guest scripts verify what they download before they extract, install or run it.
  The project tarball, `poc/db/schema.sql` and the stash binaries tarball are
  checked against SHA-256 values carried in the launch command (computed on the
  host by the framework's `digest` extension; the binaries' digest is read from the
  build VM), an absent digest fails closed, and `AMISAD_ALLOW_UNVERIFIED=1` is the
  loud override for a hand run. `rustup-init`, `bazelisk` and the NATS server are
  pinned to a release and its publisher SHA-256 instead of being piped into a shell
  or taken from `latest`. See `poc/test.md`, "Verified nested downloads".
- `poc/test/nats_installer_contracts.py` now runs under Git Bash as well as on
  Linux, and `poc/test/download_contracts.py` holds the verification contracts.

## 2026.10.11

- Shared HTTP helpers moved out of the two demo servers into
  `poc/demo/AmisAd.DemoHost.psm1`, which both already imported.
- PowerShell now has the same PSScriptAnalyzer rule set as the framework repo,
  so a finding is caught here rather than on the machine running the demo.
- The lab driver writes its per-stage logs into the running cycle's folder
  instead of the system temp dir, so the only record of each stage's
  provisioning half -- base-image check, VM creation, first boot, none of which
  reach a sequence transcript -- ships with the cycle's other artifacts. A run
  outside a cycle still uses `<temp>/amisad-tests`.
- `test/test.runner.yml` lists only its `sequences:`. The pool-control Pools
  page assigns the Framework URL and Project URL together; a pool runs this
  project when its Project URL points at this repository.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.11

Back to [Yuruna](https://yuruna.com)
