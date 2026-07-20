#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - amisad-vm-build compile step: build every release binary and
# upload the tarball to the stash service, for amisad-vm-core to download and
# deploy. This VM has the Rust toolchain but no Kubernetes; it produces
# artifacts, it does not run them. STASH_HOST (default 192.168.7.222): the
# stash-service VM the binaries are dropped into.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
. "$REAL_HOME/.cargo/env"

echo "== obtain project tree (lab: host-served tarball of amisad.dev HEAD) =="
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_HOST_IP:-}" ] || [ -z "${YURUNA_HOST_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status server" >&2
    exit 2
fi
rm -rf "$REAL_HOME/amisad.dev"
mkdir -p "$REAL_HOME/amisad.dev"
wget --no-proxy -qO /tmp/project-poc.tar.gz \
    "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-repo/project-poc.tar.gz?nocache=${RANDOM}"
tar -xzf /tmp/project-poc.tar.gz -C "$REAL_HOME/amisad.dev"
rm -f /tmp/project-poc.tar.gz

POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== stash reachability (fail fast, before the ~20-min build) =="
# HTTP :80 reachability is a proxy for scp :22 reachability (same host). The
# stash is on the bridged LAN; if this guest (NAT) cannot reach it, stop now
# instead of building and then failing at the scp upload.
STASH_HOST="${STASH_HOST:-192.168.7.222}"
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
# shellcheck disable=SC2086
tar czf /tmp/amisad-binaries.tgz -C target/release $BINS
ls -l /tmp/amisad-binaries.tgz
# The stash sink caps each file at 100 MB and truncates SILENTLY (exits 0), which
# would surface only as a corrupt gunzip on amisad-vm-core. Fail loud here instead.
SZ=$(stat -c%s /tmp/amisad-binaries.tgz)
if [ "$SZ" -ge 104857600 ]; then
    echo "binaries tarball ${SZ}B exceeds the stash 100MB per-file cap; strip binaries or split." >&2
    exit 4
fi

echo "== upload binaries to the stash service =="
# The stash records the upload (username=amisad-poc, filename=amisad-binaries.tgz)
# for later investigation; amisad-vm-core locates it by that label. scp only (the
# stash SSH server accepts the drop); no key needed - it is a write-only sink.
STASH_HOST="${STASH_HOST:-192.168.7.222}"
scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=20 \
    /tmp/amisad-binaries.tgz "amisad-poc@${STASH_HOST}:/amisad/amisad-binaries.tgz"
echo "uploaded amisad-binaries.tgz to stash ${STASH_HOST} (label amisad-poc)"

echo "amisad-vm-build COMPILE+UPLOAD PASSED"
