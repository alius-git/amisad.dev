#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# See https://yuruna.link/42010605-0008
# --- REGION: Initialize environment
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
. "$REAL_HOME/.cargo/env"

echo "== obtain project tree (lab: host-served tarball of amisad.dev HEAD) =="
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_STATUS_SERVICE_IP:-}" ] || [ -z "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status service" >&2
    exit 2
fi

# --- REGION: amisad_host_fetch
# See https://yuruna.link/4220a755-004d
amisad_host_fetch() {
    local dest="$1" path="$2" attempt
    for attempt in 1 2; do
        if [ "$attempt" -eq 2 ] && [ -x /usr/local/lib/yuruna/yuruna-host-locate.sh ]; then
            /usr/local/lib/yuruna/yuruna-host-locate.sh >/dev/null || return 1
        fi
        if [ -r /etc/yuruna/host.env ]; then
            # shellcheck disable=SC1091
            . /etc/yuruna/host.env
        fi
        if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ] && \
           wget --no-proxy --timeout=30 --tries=2 -qO "$dest" \
                "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/${path}"; then
            return 0
        fi
        if [ "$attempt" -eq 1 ]; then
            echo "host fetch of '${path}' failed; refreshing the host coordinates and retrying." >&2
        fi
    done
    return 1
}

# --- REGION: amisad_sha256
# See https://yuruna.link/42010605-0008
amisad_sha256() { # <file> -> its SHA-256 on stdout, lowercase hex
    local file="$1" out
    out=$(sha256sum "$file" 2>/dev/null) || out=$(shasum -a 256 "$file" 2>/dev/null) || return 1
    printf '%s' "${out%% *}" | tr 'A-F' 'a-f'
}

# amisad_verify_download <file> <expected sha256> <label> <variable name>
# Returns 0 when the bytes match (or when the digest is absent and the override
# is set), 1 otherwise; a refused download is deleted, never left to be reused.
# --- REGION: amisad_verify_download
amisad_verify_download() {
    local file="$1" expected="${2:-}" label="$3" variable="$4" actual
    if [ -z "$expected" ]; then
        if [ "${AMISAD_ALLOW_UNVERIFIED:-}" = "1" ]; then
            {
                echo ""
                echo "!! UNVERIFIED DOWNLOAD (AMISAD_ALLOW_UNVERIFIED=1)"
                echo "!!   input:  ${label}"
                echo "!!   cause:  ${variable} is empty, so nothing proves these bytes are the ones the host meant"
                echo "!!   effect: the download is used as it arrived. This override exists for hand runs;"
                echo "!!           a sequence never sets it."
                echo ""
            } >&2
            return 0
        fi
        rm -f -- "$file"
        {
            echo ""
            echo "!! DOWNLOAD NOT VERIFIED -- refusing to use ${label}"
            echo "!!   cause:  ${variable} is empty. The sequence puts the expected SHA-256 in this script's"
            echo "!!           launch command; an empty value means the host could not compute it (see the"
            echo "!!           host log for a digest warning) or this script was started by hand."
            echo "!!   by hand: set ${variable}=<sha256>, or AMISAD_ALLOW_UNVERIFIED=1 to use the download"
            echo "!!           unverified (a warning banner is printed)."
            echo ""
        } >&2
        return 1
    fi
    if [ "${#expected}" -ne 64 ] || [ -n "${expected//[0-9A-Fa-f]/}" ]; then
        rm -f -- "$file"
        echo "!! DOWNLOAD NOT VERIFIED -- ${variable} is not a SHA-256 (64 hex characters): ${expected}" >&2
        return 1
    fi
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    actual=$(amisad_sha256 "$file") || actual=''
    if [ "$actual" = "$expected" ]; then
        echo "  integrity: sha256 verified (${label})"
        return 0
    fi
    rm -f -- "$file"
    {
        echo ""
        echo "!! INTEGRITY MISMATCH -- refusing to use ${label}"
        echo "!!   expected: ${expected}"
        echo "!!   actual:   ${actual:-<unreadable>}"
        echo "!!   The download was deleted. Either the bytes changed after the host hashed them (the"
        echo "!!   clone moved, or something on the path answered instead of the status service) or"
        echo "!!   the host and this guest disagree about which input this is."
        echo ""
    } >&2
    return 1
}
# End download verification

# Downloads land in a private directory (mode 0700), not loose in /tmp: another
# local user could otherwise swap a file between its digest check and its use.
AMISAD_WORK=$(mktemp -d "${TMPDIR:-/tmp}/amisad-fetch.XXXXXX")
trap 'rm -rf -- "$AMISAD_WORK"' EXIT

# Why this endpoint (and not /yuruna-repo/*): see poc/test.md "Repo delivery".
# The previous tree is replaced only after the new archive verified.
amisad_host_fetch "$AMISAD_WORK/project-poc.tar.gz" "yuruna-project-archive.tar.gz?nocache=${RANDOM}"
amisad_verify_download "$AMISAD_WORK/project-poc.tar.gz" "${AMISAD_PROJECT_ARCHIVE_SHA256:-}" \
    "the project archive (yuruna-project-archive.tar.gz)" AMISAD_PROJECT_ARCHIVE_SHA256 || exit 7
rm -rf "$REAL_HOME/amisad.dev"
mkdir -p "$REAL_HOME/amisad.dev"
tar -xzf "$AMISAD_WORK/project-poc.tar.gz" -C "$REAL_HOME/amisad.dev"
rm -f "$AMISAD_WORK/project-poc.tar.gz"

POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== stash reachability (fail fast, before the ~20-min build) =="
# See https://yuruna.link/42010605-0008
if [ -z "${STASH_HOST:-}" ]; then
    echo "STASH_HOST is empty - the sequence supplies it from \${ext:stash-service.ResolveHost(...)} and the cycle's warm-up publishes the address it verified. Nowhere to upload binaries; aborting before build." >&2
    exit 3
fi
curl -fsS --noproxy '*' --connect-timeout 20 "http://${STASH_HOST}/healthz" >/dev/null || {
    echo "STASH UNREACHABLE at http://${STASH_HOST} - cannot upload binaries; aborting before build." >&2
    exit 3
}

echo "== build (bazel gate; cargo fallback ONLY on registry TLS trust) =="
# The lab caching proxy intercepts HTTPS with a CA absent from Bazel's bundled
# JVM truststore (PKIX on bcr.bazel.build/crates.io); only THAT failure may
# fall back to cargo. Any other bazel failure (bad MODULE.bazel, lock out of
# sync, MSRV) must fail loudly - the crate_universe wiring is part of what
# this gate verifies.
BAZEL_LOG=/tmp/bazel-gate.log
: > "$BAZEL_LOG"
if sudo apt-get install -y ca-certificates-java >/dev/null 2>&1 && \
   bazel --host_jvm_args=-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts build //... >"$BAZEL_LOG" 2>&1; then
    echo "bazel gate: PASS"
elif grep -qE 'PKIX|trustAnchors|SSLHandshake' "$BAZEL_LOG"; then
    echo "WARNING: bazel gate skipped (registry TLS trust); using cargo build"
else
    echo "bazel gate FAILED for a non-TLS reason; last 40 lines:" >&2
    tail -40 "$BAZEL_LOG" >&2
    exit 5
fi

echo "== test + release build (produces all 12 binaries) =="
cargo test --workspace
cargo build --release --workspace

echo "== pack binaries =="
BINS="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc slice-runtime buyer-client"
# Label amisad-<arch>-binaries: see poc/test.md "Stash artifact naming".
ARCH=$(uname -m)
TARBALL="/tmp/amisad-${ARCH}-binaries.tgz"
# shellcheck disable=SC2086
tar czf "$TARBALL" -C target/release $BINS
ls -l "$TARBALL"
# The stash sink caps each file at 100 MB and truncates SILENTLY (exits 0), which
# would surface only as a corrupt gunzip on amisad-core. Fail loud here instead.
SZ=$(stat -c%s "$TARBALL")
if [ "$SZ" -ge 104857600 ]; then
    echo "binaries tarball ${SZ}B exceeds the stash 100MB per-file cap; strip binaries or split." >&2
    exit 4
fi

echo "== upload binaries to the stash service =="
# See https://yuruna.link/42010605-0008
SCP_LOG=/tmp/scp-upload.log
SCP_ATTEMPTS=3
SCP_BACKOFF=5
SCP_TRY=1
SCP_RC=0
while [ "$SCP_TRY" -le "$SCP_ATTEMPTS" ]; do
    echo "scp upload attempt ${SCP_TRY}/${SCP_ATTEMPTS}: ${TARBALL} -> amisad-poc@${STASH_HOST}"
    SCP_RC=0
    scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=20 \
        "$TARBALL" "amisad-poc@${STASH_HOST}:/amisad/amisad-${ARCH}-binaries.tgz" \
        2>"$SCP_LOG" || SCP_RC=$?
    if [ "$SCP_RC" -eq 0 ]; then
        break
    fi
    echo "scp upload attempt ${SCP_TRY}/${SCP_ATTEMPTS} failed (rc=${SCP_RC}); scp reported:" >&2
    sed 's/^/    /' "$SCP_LOG" >&2
    if [ "$SCP_TRY" -lt "$SCP_ATTEMPTS" ]; then
        echo "scp upload: retrying in ${SCP_BACKOFF}s" >&2
        sleep "$SCP_BACKOFF"
    fi
    SCP_TRY=$((SCP_TRY + 1))
done
if [ "$SCP_RC" -ne 0 ]; then
    echo "scp upload failed after ${SCP_ATTEMPTS} attempts; the binaries never reached stash ${STASH_HOST} and amisad-core has nothing to deploy." >&2
    exit 6
fi
echo "uploaded amisad-${ARCH}-binaries.tgz to stash ${STASH_HOST} (label amisad-poc)"

echo "amisad-build COMPILE+UPLOAD PASSED"
