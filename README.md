# amisad.dev
AmisAd development

## Planning documents

- [personas.md](plan/personas.md) -- Profiles of the eleven user roles the AmisAd ecosystem serves: motivations, responsibilities, and interaction points.
- [applications.md](plan/applications.md) -- The application ecosystem: each application's business objective, core functionality, and architectural paradigms, plus the shared platform foundations.
- [scenarios.md](plan/scenarios.md) -- Ten prioritized end-to-end verification sequences for the Yuruna framework, with full persona and component traceability.
- [design.md](plan/design.md) -- Master POC design: stack decisions, lab VM topology, mock boundaries, and growth path, with Mermaid diagrams under [plan/design/](plan/design/) (indexed in [section 9](plan/design.md#9-diagrams)).

## Proof of concept

- [poc/](poc/README.md) -- POC implementation: Bazel/Cargo workspace, service contracts, deploy config, and the Yuruna lab setup for running the scenarios.
- [poc/STATUS.s001.fulfillment.md](poc/STATUS.s001.fulfillment.md) -- Historical record (2026-07-19) of the s001.fulfillment unattended verification run. Current test automation and topology: [poc/test.md](poc/test.md).

On Hyper-V, [the storage admission policy](test/host-storage.requirements.json)
reserves 20 GiB for the concurrent core and two edge VMs, a 64 GiB disk and
checkpoint growth allowance (16 GiB per VM), and a 2 GiB volume reserve.
A new topology sharing one storage volume therefore needs 86 GiB available.
The growth allowance is a conservative policy, not a measured per-VM size or a
guarantee against later growth. The build VM is stopped before the final
topology starts, so it adds no concurrent runtime memory reservation.
Sequential provisioning also needs a 12 GiB runtime reservation on Hyper-V's
default configuration volume before VM storage is moved to its final location.
When both paths share a volume, the larger runtime reservation applies; when
they differ, each volume is checked separately.

Frameworks that support the policy check it before admitting a cycle.
`Initialize-Lab.ps1` also checks before provisioning and rechecks runtime
capacity before final starts, without charging already provisioned disk growth
again. Checks use the VM storage volumes; spare space on another drive does not
satisfy them. Older framework drivers remain supported and explicitly record
that storage admission is unavailable. When a start fails, stage logs retain
its storage evidence and separate diagnostic directories for each involved VM.

## Software inventory

- [Software bill of materials](docs/sbom/README.md) -- Repository, host, and guest inventories in SPDX, CycloneDX, and SWID formats, with automatic maintenance before commits.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
