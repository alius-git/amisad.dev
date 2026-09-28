#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - install NATS JetStream as a host systemd service. Deliberately
# NOT in-cluster: docker.io pulls fail in this lab (invalid_token via the
# caching path); the GitHub release binary avoids Docker Hub.
# Services reach NATS at <node-ip>:4222; the in-cluster Service indirection
# returns when the event-driven scenarios actually wire JetStream in.
set -euo pipefail

# Pinned (not 'latest'): resolving latest needs the unauthenticated GitHub
# releases API, which 403s behind the shared NAT egress. Bump by editing this line.
NATS_VERSION=v2.15.0
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) NARCH=amd64 ;;
    aarch64) NARCH=arm64 ;;
    *) NARCH=amd64 ;;
esac

changed=0
installed_version=$(/usr/local/bin/nats-server --version 2>/dev/null || true)
if [ "$installed_version" != "nats-server: $NATS_VERSION" ]; then
    # Same exposure as the bazelisk download: one transient empty reply through
    # the lab proxy ends the script under `set -e`. fetch-and-execute exports the
    # framework's retry wrappers into this environment; without them, a bounded
    # single attempt with wget's own retries is the most that can be asked for.
    NATS_URL="https://github.com/nats-io/nats-server/releases/download/${NATS_VERSION}/nats-server-${NATS_VERSION}-linux-${NARCH}.tar.gz"
    if declare -F wget_try >/dev/null 2>&1; then
        wget_try -qO /tmp/nats-server.tar.gz "$NATS_URL"
    else
        wget --tries=3 --waitretry=5 --retry-connrefused --read-timeout=60 \
            -qO /tmp/nats-server.tar.gz "$NATS_URL"
    fi
    tar -xzf /tmp/nats-server.tar.gz -C /tmp
    [ "$(/tmp/nats-server-${NATS_VERSION}-linux-${NARCH}/nats-server --version)" = "nats-server: $NATS_VERSION" ]
    sudo install -m 0755 "/tmp/nats-server-${NATS_VERSION}-linux-${NARCH}/nats-server" /usr/local/bin/nats-server
    changed=1
    rm -rf /tmp/nats-server.tar.gz "/tmp/nats-server-${NATS_VERSION}-linux-${NARCH}"
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
