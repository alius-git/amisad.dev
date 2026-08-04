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
rm -rf "$REAL_HOME/amisad.dev"
mkdir -p "$REAL_HOME/amisad.dev"
# Why this endpoint (and not /yuruna-repo/*): see poc/test.md "Repo delivery".
wget --no-proxy -qO /tmp/project-poc.tar.gz \
    "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-project-archive.tar.gz?nocache=${RANDOM}"
tar -xzf /tmp/project-poc.tar.gz -C "$REAL_HOME/amisad.dev"
rm -f /tmp/project-poc.tar.gz

POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== stash reachability (fail fast, before the ~20-min build) =="
# HTTP :80 reachability is a proxy for scp :22 reachability (same host). The
# stash is on the bridged LAN; if this guest (NAT) cannot reach it, stop now
# instead of building and then failing at the scp upload.
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
# STASH_HOST was required and proven reachable by the pre-flight above.
scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=20 \
    "$TARBALL" "amisad-poc@${STASH_HOST}:/amisad/amisad-${ARCH}-binaries.tgz"
echo "uploaded amisad-${ARCH}-binaries.tgz to stash ${STASH_HOST} (label amisad-poc)"

echo "amisad-build COMPILE+UPLOAD PASSED"
