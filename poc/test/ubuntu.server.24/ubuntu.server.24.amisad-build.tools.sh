#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - install the build toolchains on the build VM:
# rustup (pinned stable Rust), bazelisk (as /usr/local/bin/bazel), git, python3.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y git curl build-essential pkg-config python3

if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    # Rust version in lockstep with poc/MODULE.bazel rust.toolchain (see the
    # comment there) and the rust:*-slim Dockerfiles; bump all together.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain 1.96.1
fi
. "$HOME/.cargo/env"
cargo --version
rustc --version

if ! command -v bazel >/dev/null 2>&1; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) BARCH=amd64 ;;
        aarch64) BARCH=arm64 ;;
        *) BARCH=amd64 ;;
    esac
    sudo curl -fsSL -o /usr/local/bin/bazel \
        "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${BARCH}"
    sudo chmod +x /usr/local/bin/bazel
fi

# Verify rather than assume: every tool below is consumed by the compile
# step running from a RESTORED snapshot, where a missing one surfaces as a
# bare "command not found" with no trace of which install stage dropped it.
for tool in cargo rustc bazel git python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "tool not on PATH after install: $tool" >&2; exit 1; }
done

# Flush before returning. The host freezes this VM's disk for a snapshot as
# soon as this script exits, and it does not ask the guest to write back
# first; whatever is still in the page cache at that instant is simply not
# in the snapshot. The failure is silent and deferred -- the file is readable
# for the rest of this SSH session and missing only once the snapshot is
# restored, so it surfaces as an unrelated "command not found" in a later
# sequence. Large, recently written files are lost first: an 8 MB binary
# installed as the last action here has not aged past the filesystem's
# writeback interval, while the small files written seconds earlier have.
sync

echo "AmisAd build tools installed"
