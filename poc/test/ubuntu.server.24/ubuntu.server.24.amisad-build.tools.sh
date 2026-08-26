#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - install the build toolchains on the build VM:
# rustup (pinned stable Rust), bazelisk (as /usr/local/bin/bazel), git, python3.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y git curl build-essential pkg-config python3

# fetch-and-execute.sh sources the framework retry lib and exports its
# wrappers, so they are already in scope on the normal path; sourcing here
# keeps a direct `bash <this script>` run working too. When neither provides
# the lib, every install below runs exactly once, unwrapped.
if ! declare -F _yuruna_retry >/dev/null 2>&1 && [ -r /usr/local/lib/yuruna/yuruna-retry.sh ]; then
    # shellcheck disable=SC1091
    . /usr/local/lib/yuruna/yuruna-retry.sh
fi

# Run $@ through the retry ladder when the lib is present, plain otherwise.
amisad_retry() {
    local label="$1"; shift
    if declare -F _yuruna_retry >/dev/null 2>&1; then
        _yuruna_retry "$label" "$@"
    else
        "$@"
    fi
}

# rustup's installer downloads rustup-init with its OWN curl, which does not
# retry a partial body: one truncated transfer (curl 18, "transfer closed with
# N bytes remaining to read") ends the install and, under `set -e`, the cycle.
# Retrying just the outer fetch would not help -- the failing transfer is the
# inner one -- so the whole pipeline is the retried unit.
amisad_install_rustup() {
    # Rust version in lockstep with poc/MODULE.bazel rust.toolchain (see the
    # comment there) and the rust:*-slim Dockerfiles; bump all together.
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain 1.96.1
}

if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    amisad_retry rustup_install amisad_install_rustup
fi
. "$HOME/.cargo/env"
cargo --version
rustc --version

# Retried for the same reason the rustup install above is: a single "empty
# reply from server" through the lab proxy -- a transient the lab does
# produce -- would exit the script under `set -e` and cost the whole cycle,
# after rust had already installed cleanly.
#
# The fetch is unprivileged and the install is the only privileged step. sudo
# inside the retried unit would put the privilege where the retry cannot see
# whether it was the download or the elevation that failed, and curl writing
# straight to /usr/local/bin leaves a truncated binary on a partial transfer.
amisad_install_bazelisk() {
    curl -fsSL --connect-timeout 15 --max-time 300 -o /tmp/bazelisk \
        "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${BARCH}"
}

if ! command -v bazel >/dev/null 2>&1; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) BARCH=amd64 ;;
        aarch64) BARCH=arm64 ;;
        *) BARCH=amd64 ;;
    esac
    amisad_retry bazelisk_install amisad_install_bazelisk
    sudo install -m 0755 /tmp/bazelisk /usr/local/bin/bazel
    rm -f /tmp/bazelisk
fi

# Verify rather than assume: every tool below is consumed by the compile
# step running from a RESTORED snapshot, where a missing one surfaces as a
# bare "command not found" with no trace of which install stage dropped it.
for tool in cargo rustc bazel git python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "tool not on PATH after install: $tool" >&2; exit 1; }
done

# Flush before the snapshot: see poc/test.md "Snapshot page-cache flush".
sync

echo "AmisAd build tools installed"
