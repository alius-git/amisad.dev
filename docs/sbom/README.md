<a id="42bc1378-0001"></a>

# Software bill of materials

The inventories separate AmisAd repository dependencies, host software, and
guest software. Their shared formats and maintenance rules are documented at
[Yuruna SBOM maintenance](https://yuruna.link/427fb0be-0001).

| Scope | SPDX 2.2.1 JSON | CycloneDX 1.7 JSON | SWID 2015 XML |
|---|---|---|---|
| Repository | [repository.spdx.json](repository.spdx.json) | [repository.cdx.json](repository.cdx.json) | [repository.swidtag](repository.swidtag) |
| Hosts | [hosts.spdx.json](hosts.spdx.json) | [hosts.cdx.json](hosts.cdx.json) | [hosts.swidtag](hosts.swidtag) |
| Guests | [guests.spdx.json](guests.spdx.json) | [guests.cdx.json](guests.cdx.json) | [guests.swidtag](guests.swidtag) |

SPDX is the ISO/IEC 5962:2021 exchange format. CycloneDX follows ECMA-424,
second edition. SWID tags use the 2015 software-identification XML vocabulary.
Each scope has all three representations.

<a id="42bc1378-0002"></a>

## What the inventory establishes

Repository evidence includes the Cargo workspace and its lockfile, the npm
manifest and lockfile, Flutter declarations, Bazel module and toolchain pins,
and Dockerfile base images. Host and guest inventories include software named
by setup and deployment scripts, including the Rust/Bazel build tools and NATS
server. These declarations describe intended installation; they do not prove
which packages are installed on a running machine.

Generation reads existing files only. It does not restore packages, query
registries, scan container contents, or create missing locks. Cargo and npm
locks supply their recorded versions, relationships, and checksums. The Flutter
lockfile and Android scaffolding are generated outside the tracked source tree,
so their resolved Pub/Gradle packages remain outside this inventory. Bazel
registry transitives and container operating-system packages are likewise
unresolved without tracked resolution evidence. Version ranges and floating
image tags remain constraints. Completeness notes and source references make
these limits visible in the inventories.

<a id="42bc1378-0003"></a>

## Update and compare

Run from the repository root with Python 3.11 or newer and Git:

```sh
python tools/Sync-Sbom.py --update
python tools/Sync-Sbom.py --check
```

Use `python3` if that is the local command. Replacing a changed artifact first
saves its old content at the same path with `.previous` appended. Initial
generation has no previous file. Later updates preserve the immediately
preceding version, while unchanged output stays untouched.

```sh
git diff --no-index docs/sbom/guests.spdx.json.previous docs/sbom/guests.spdx.json
```

<a id="42bc1378-0004"></a>

## Before a commit

The tracked pre-commit hook regenerates the three inventories from staged
source files and stages changed outputs and their `.previous` copies. It runs
locally without network access. Enable it in a clone with:

```sh
git config core.hooksPath tools/githooks
```

To perform its inventory operation explicitly:

```sh
python tools/Sync-Sbom.py --update --staged --stage
```

Hook activation belongs to local Git configuration; a fresh clone needs that
configuration to run the tracked hook automatically.

Back to [amisad.dev](../../README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.

Last review: 2026.10.11
