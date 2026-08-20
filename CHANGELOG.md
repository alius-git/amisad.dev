# Changelog

Notable changes to amisad.dev. This repository holds the demo and
proof-of-concept material the Yuruna framework deploys as a project; the
framework's own history lives in
[yuruna/CHANGELOG.md](https://github.com/alissonsol/yuruna/blob/main/CHANGELOG.md).

Versions track the framework release the material was last exercised against,
not an independent release line -- the POC is only meaningful paired with a
framework that can deploy it.

## 2026.08.20

- Shared HTTP helpers moved out of the two demo servers into
  `poc/demo/AmisAd.DemoHost.psm1`, which both already imported.
- PowerShell now has the same PSScriptAnalyzer rule set as the framework repo,
  so a finding is caught here rather than on the machine running the demo.
- The lab driver writes its per-stage logs into the running cycle's folder
  instead of the system temp dir, so the only record of each stage's
  provisioning half -- base-image check, VM creation, first boot, none of which
  reach a sequence transcript -- ships with the cycle's other artifacts. A run
  outside a cycle still uses `<temp>/amisad-tests`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.20

Back to [Yuruna](https://yuruna.com)
