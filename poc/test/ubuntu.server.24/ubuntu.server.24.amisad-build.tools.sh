#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42dec72c-56a0-4850-b10c-ab6a73851d50
# AmisAd POC - install the build toolchains on the build VM:
# rustup (pinned stable Rust), bazelisk (as /usr/local/bin/bazel), git, python3.
# --- REGION: Initialize environment
set -euo pipefail

# An enrolled build guest has a verified provisioner before its toolchain is
# installed. Cold guests can still bootstrap the first signed build below.
artifact_plan=/etc/yuruna/amisad-artifacts.json
if [[ -e $artifact_plan || -L $artifact_plan ]]; then
    if [[ ! -f $artifact_plan || -L $artifact_plan ]]; then
        echo 'The enrolled AmisAd artifact plan is not a regular file.' >&2
        exit 7
    fi
    artifact_root=/usr/local/lib/yuruna/amisad-artifacts
    bootstrap=$(sudo /usr/local/lib/yuruna/install-rust-artifacts --plan-file \
        "$artifact_plan" "$artifact_root" amisad-provision framework-revision) || exit 7
    provision="$bootstrap/amisad-provision"
    if [[ ${bootstrap%/*} != "$artifact_root" || ! ${bootstrap##*/} =~ ^[a-f0-9]{64}$ ||
          ! -f $provision || -L $provision || ! -x $provision ]]; then
        echo 'The verified AmisAd provisioner is unavailable.' >&2
        exit 7
    fi
    exec "$provision" build-tools
fi

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
# --- REGION: amisad_retry
amisad_retry() {
    local label="$1"; shift
    if declare -F _yuruna_retry >/dev/null 2>&1; then
        _yuruna_retry "$label" "$@"
    else
        "$@"
    fi
}

# --- REGION: amisad_verify_pinned
# See https://yuruna.link/42010605-00ce
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
# End pinned download verification

# rustup-init, pinned. The rustup.rs shell installer is rewritten whenever rustup
# is and carries no digest; the binary of a named release does, so that is what
# runs. Bump the version and both digests together
# (https://static.rust-lang.org/rustup/archive/<version>/<target>/rustup-init.sha256).
RUSTUP_VERSION=1.29.3
RUSTUP_SHA256_X86_64=b1c8cb14e30889e7e2999e6b69e62d9e9b9ffc0f4df8180564d306d9680e6c55
RUSTUP_SHA256_AARCH64=9f608c142e0e38a78957d0661ba1dfaf0b6fb37184cfaa4b9a0aa57af6184282

# A truncated transfer (curl 18, "transfer closed with N bytes remaining to
# read") ends the install and, under `set -e`, the cycle, so download, check and
# run together are the retried unit.
# --- REGION: amisad_install_rustup
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
        "$work/rustup-init" -y --default-toolchain 1.99.1 || rc=$?
    fi
    rm -rf -- "$work"
    return "$rc"
}

if ! command -v rustup >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/rustup" ]; then
    amisad_retry rustup_install amisad_install_rustup
fi
# shellcheck disable=SC1091
. "$HOME/.cargo/env"

# Existing snapshots may carry an older default toolchain even when rustup is installed.
# --- REGION: amisad_select_rust_toolchain
amisad_select_rust_toolchain() {
    local current
    current=$(rustc --version 2>/dev/null || true)
    if [[ "$current" != "rustc 1.99.1 "* ]]; then
        amisad_retry rust_toolchain rustup toolchain install 1.99.1 --profile minimal || return $?
        rustup default 1.99.1
    fi
}
amisad_select_rust_toolchain
cargo --version
rustc --version

# See https://yuruna.link/42010605-00cd
BAZELISK_VERSION=v1.30.0
BAZELISK_SHA256_AMD64=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8
BAZELISK_SHA256_ARM64=b2bcc040c213b44586b121bda6d983c35df121b917c3a7a66fb16f2fa0df1a4f
# --- REGION: amisad_install_bazelisk
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
    # A GitHub release fetch gets the retry library's release window: 30 minutes
    # with each backoff capped at two minutes (automation/yuruna-retry.sh,
    # _yuruna_retry_release_bounds), so a release outage is waited out.
    YURUNA_RETRY_WINDOW_SECONDS="${YURUNA_RETRY_WINDOW_SECONDS:-1800}" \
    YURUNA_RETRY_MAX_DELAY_SECONDS="${YURUNA_RETRY_MAX_DELAY_SECONDS:-120}" \
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
