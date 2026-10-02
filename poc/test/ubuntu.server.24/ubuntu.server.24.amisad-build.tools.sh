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

# --- amisad pinned download check: identical copy in tools.sh and nats.sh ---
# rustup-init, bazelisk and the NATS server are downloaded from their publishers
# and then executed or installed as root, so each is checked against a SHA-256
# pinned in THIS script before use. The pins are the publishers' own values (the
# .sha256 file beside each rustup-init, the digest on each bazelisk release
# asset, the release's SHA256SUMS for NATS), recorded when the version was
# chosen. They live in a script that fetch-and-execute verified against the
# digest the host typed into the launch command, so they are as trustworthy as
# the script. A mismatch deletes the download, so a retried unit fetches afresh.
amisad_verify_pinned() { # <file> <sha256 pinned in this script> <label>
    local file="$1" want="$2" label="$3" have
    have=$(sha256sum "$file" 2>/dev/null) || have=''
    have=${have%% *}
    if [ -n "$have" ] && [ "$have" = "$want" ]; then
        echo "  integrity: sha256 verified (${label})"
        return 0
    fi
    rm -f -- "$file"
    {
        echo ""
        echo "!! INTEGRITY MISMATCH -- refusing to use ${label}"
        echo "!!   pinned:   ${want}"
        echo "!!   actual:   ${have:-<unreadable>}"
        echo "!!   The download was deleted and nothing was run or installed from it: the publisher's"
        echo "!!   file is not the one this script pins (a truncated transfer, something on the path,"
        echo "!!   or a release that replaced the pinned one)."
        echo ""
    } >&2
    return 1
}
# --- end amisad pinned download check ---

# rustup-init, pinned. The rustup.rs shell installer is rewritten whenever rustup
# is and carries no digest; the binary of a named release does, so that is what
# runs. Bump the version and both digests together
# (https://static.rust-lang.org/rustup/archive/<version>/<target>/rustup-init.sha256).
RUSTUP_VERSION=1.29.1
RUSTUP_SHA256_X86_64=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
RUSTUP_SHA256_AARCH64=15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433

# A truncated transfer (curl 18, "transfer closed with N bytes remaining to
# read") ends the install and, under `set -e`, the cycle, so download, check and
# run together are the retried unit.
amisad_install_rustup() {
    local target sha work rc=0
    case "$(uname -m)" in
        aarch64) target=aarch64-unknown-linux-gnu; sha=$RUSTUP_SHA256_AARCH64 ;;
        *) target=x86_64-unknown-linux-gnu; sha=$RUSTUP_SHA256_X86_64 ;;
    esac
    work=$(mktemp -d "${TMPDIR:-/tmp}/amisad-rustup.XXXXXX")
    curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 600 -o "$work/rustup-init" \
        "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${target}/rustup-init" || rc=$?
    if [ "$rc" -eq 0 ]; then
        amisad_verify_pinned "$work/rustup-init" "$sha" "rustup-init ${RUSTUP_VERSION} (${target})" || rc=1
    fi
    if [ "$rc" -eq 0 ]; then
        chmod 0755 "$work/rustup-init"
        # Rust version in lockstep with poc/MODULE.bazel rust.toolchain (see the
        # comment there) and the rust:*-slim Dockerfiles; bump all together.
        "$work/rustup-init" -y --default-toolchain 1.96.1 || rc=$?
    fi
    rm -rf -- "$work"
    return "$rc"
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
#
# bazelisk is pinned to a release, not to whatever "latest" is on the day of the
# run, because an executable installed as root is only worth checking if there
# is one file to check it against. Bump the version and both digests together;
# the release page lists each asset's SHA-256. The download sits in a private
# directory so no other local user can swap it between the check and the install.
BAZELISK_VERSION=v1.29.0
BAZELISK_SHA256_AMD64=5a408715e932c0250d28bd84555f12edbf70117de42f9181691c736eacc4a992
BAZELISK_SHA256_ARM64=e20e8b0f4f240091b7a55bf17b9398bd4f40ee70ae0208dff95dd4c445fb4010
amisad_install_bazelisk() {
    local sha rc=0
    case "$BARCH" in
        arm64) sha=$BAZELISK_SHA256_ARM64 ;;
        *) sha=$BAZELISK_SHA256_AMD64 ;;
    esac
    curl -fsSL --connect-timeout 15 --max-time 300 -o "$BAZELISK_DIR/bazelisk" \
        "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${BARCH}" || rc=$?
    if [ "$rc" -eq 0 ]; then
        amisad_verify_pinned "$BAZELISK_DIR/bazelisk" "$sha" "bazelisk ${BAZELISK_VERSION} (linux-${BARCH})" || rc=1
    fi
    return "$rc"
}

if ! command -v bazel >/dev/null 2>&1; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) BARCH=amd64 ;;
        aarch64) BARCH=arm64 ;;
        *) BARCH=amd64 ;;
    esac
    BAZELISK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/amisad-bazelisk.XXXXXX")
    amisad_retry bazelisk_install amisad_install_bazelisk
    sudo install -m 0755 "$BAZELISK_DIR/bazelisk" /usr/local/bin/bazel
    rm -rf -- "$BAZELISK_DIR"
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
