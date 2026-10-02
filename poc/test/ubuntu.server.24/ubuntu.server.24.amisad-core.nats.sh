#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - install NATS JetStream as a host systemd service. Deliberately
# NOT in-cluster: docker.io pulls fail in this lab (invalid_token via the
# caching path); the GitHub release binary avoids Docker Hub.
# Services reach NATS at <node-ip>:4222; the in-cluster Service indirection
# returns when the event-driven scenarios actually wire JetStream in.
set -euo pipefail

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

# Pinned (not 'latest'): resolving latest needs the unauthenticated GitHub
# releases API, which 403s behind the shared NAT egress. Bump by editing these
# lines: the version and both digests together. The digests are the release's own
# SHA256SUMS entries for the two linux tarballs.
NATS_VERSION=v2.15.0
NATS_SHA256_AMD64=5d2c51caca950333aba84911df7d377f826f3a59ec36061c6539105084f65c92
NATS_SHA256_ARM64=cdc208f5a3f42963a52b6ab06ef65626bb870315dc936e26ba571780c6351112
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) NARCH=amd64; NATS_SHA256=$NATS_SHA256_AMD64 ;;
    aarch64) NARCH=arm64; NATS_SHA256=$NATS_SHA256_ARM64 ;;
    *) NARCH=amd64; NATS_SHA256=$NATS_SHA256_AMD64 ;;
esac

changed=0
installed_version=$(/usr/local/bin/nats-server --version 2>/dev/null || true)
if [ "$installed_version" != "nats-server: $NATS_VERSION" ]; then
    # Same exposure as the bazelisk download: one transient empty reply through
    # the lab proxy ends the script under `set -e`. fetch-and-execute exports the
    # framework's retry wrappers into this environment; without them, a bounded
    # single attempt with wget's own retries is the most that can be asked for.
    NATS_URL="https://github.com/nats-io/nats-server/releases/download/${NATS_VERSION}/nats-server-${NATS_VERSION}-linux-${NARCH}.tar.gz"
    # A private directory (mode 0700), not loose files in /tmp: another local user
    # could otherwise swap the tarball between its check and its extraction.
    NATS_WORK=$(mktemp -d "${TMPDIR:-/tmp}/amisad-nats.XXXXXX")
    if declare -F wget_try >/dev/null 2>&1; then
        wget_try -qO "$NATS_WORK/nats-server.tar.gz" "$NATS_URL"
    else
        wget --tries=3 --waitretry=5 --retry-connrefused --read-timeout=60 \
            -qO "$NATS_WORK/nats-server.tar.gz" "$NATS_URL"
    fi
    amisad_verify_pinned "$NATS_WORK/nats-server.tar.gz" "$NATS_SHA256" "the NATS server ${NATS_VERSION} (linux-${NARCH})" || {
        rm -rf -- "$NATS_WORK"
        exit 7
    }
    tar -xzf "$NATS_WORK/nats-server.tar.gz" -C "$NATS_WORK"
    [ "$("$NATS_WORK/nats-server-${NATS_VERSION}-linux-${NARCH}/nats-server" --version)" = "nats-server: $NATS_VERSION" ]
    sudo install -m 0755 "$NATS_WORK/nats-server-${NATS_VERSION}-linux-${NARCH}/nats-server" /usr/local/bin/nats-server
    changed=1
    rm -rf -- "$NATS_WORK"
fi

unit_file=$(mktemp)
trap 'rm -f "$unit_file"' EXIT
cat > "$unit_file" <<'UNIT'
[Unit]
Description=NATS JetStream (AmisAd POC)
After=network-online.target

[Service]
ExecStart=/usr/local/bin/nats-server -js -m 8222
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
if ! cmp -s "$unit_file" /etc/systemd/system/nats.service; then
    sudo install -m 0644 "$unit_file" /etc/systemd/system/nats.service
    sudo systemctl daemon-reload
    changed=1
fi
sudo systemctl enable nats
if [ "$changed" -eq 1 ]; then
    sudo systemctl restart nats
else
    sudo systemctl start nats
fi

for _ in $(seq 1 30); do
    if curl -sf http://localhost:8222/healthz >/dev/null 2>&1 &&
        curl -sf http://localhost:8222/varz | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin).get("version") != sys.argv[1])' "${NATS_VERSION#v}"; then
        # A snapshot without writeback would lose the just-written NATS
        # binary/unit -- see poc/test.md "Snapshot page-cache flush".
        sync
        echo "NATS JetStream deployed"
        exit 0
    fi
    sleep 2
done
echo "NATS failed to become healthy" >&2
sudo systemctl status nats --no-pager | tail -10 || true
exit 1
