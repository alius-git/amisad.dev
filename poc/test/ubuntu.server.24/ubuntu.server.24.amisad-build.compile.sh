#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - amisad-build compile step: build every release binary and
# upload the tarball to the stash service, for amisad-core to download and
# deploy. This VM has the Rust toolchain but no Kubernetes; it produces
# artifacts, it does not run them. STASH_HOST: the stash service the binaries
# are dropped into. REQUIRED, and with no default -- the sequence supplies it
# from ${ext:stash-service.ResolveHost(...)}, which returns the address the
# cycle's warm-up resolved and confirmed answers /healthz. A run that reaches
# this script with no published address stops immediately rather than shipping
# a build's binaries at a guessed host.
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

# --- REGION: https://yuruna.link/network#why-host-coordinates-are-re-read-per-use
amisad_host_fetch() {
    local dest="$1" path="$2" attempt
    for attempt in 1 2; do
        if [ "$attempt" -eq 2 ] && [ -x /usr/local/lib/yuruna/yuruna-host-locate.sh ]; then
            /usr/local/lib/yuruna/yuruna-host-locate.sh >/dev/null 2>&1 || true
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

rm -rf "$REAL_HOME/amisad.dev"
mkdir -p "$REAL_HOME/amisad.dev"
# Why this endpoint (and not /yuruna-repo/*): see poc/test.md "Repo delivery".
amisad_host_fetch /tmp/project-poc.tar.gz "yuruna-project-archive.tar.gz?nocache=${RANDOM}"
tar -xzf /tmp/project-poc.tar.gz -C "$REAL_HOME/amisad.dev"
rm -f /tmp/project-poc.tar.gz

POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== stash reachability (fail fast, before the ~20-min build) =="
# What this establishes: the address is populated and the host answers on the
# bridged LAN from this guest's NAT. That is the failure worth catching before
# a ~20-minute build -- a wrong or unroutable address costs the whole build.
# What it does NOT establish: /healthz is served by the HTTP listener alone and
# says nothing about sshd on :22, the share the drop lands on, or the metadata
# index that records it. A few-byte GET is also nowhere near a multi-megabyte
# transfer. A green probe here still leaves the upload able to fail, which is
# why the upload carries its own retry rather than trusting this result.
# No default address: the caller supplies one it already verified, and guessing
# here would send a build's binaries at whatever answers on someone's network.
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
# The stash records the upload (username=amisad-poc, filename=amisad-<arch>-binaries.tgz)
# for later investigation; amisad-core locates it by that label. scp only (the
# stash SSH server accepts the drop); no key needed - it is a write-only sink.
# STASH_HOST was reachable at the pre-flight above, which is weaker than it
# sounds: that was an HTTP GET, not this transfer.
#
# Bounded retry, in the shape amisad_host_fetch above already uses. Every way
# this drop can fail reaches the client as scp's generic "lost connection" --
# the server closes the channel without stating a reason, so a transport drop
# and a server-side refusal of the upload are indistinguishable from here.
# A retry is the right answer to both: it gets a fresh connection, and the
# server allocates a fresh identifier for the new session. Bounded at three so
# a sink that is genuinely gone still fails the step instead of looping.
#
# scp's stderr is captured per attempt and replayed under the attempt label
# because the cycle transcript interleaves several guests: a bare
# "lost connection" in that stream cannot be traced to the attempt that
# emitted it, and a silent retry reads as a hang.
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
