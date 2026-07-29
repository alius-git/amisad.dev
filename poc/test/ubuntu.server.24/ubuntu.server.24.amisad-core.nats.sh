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
NATS_VERSION=v2.14.3
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) NARCH=amd64 ;;
    aarch64) NARCH=arm64 ;;
    *) NARCH=amd64 ;;
esac

if ! command -v nats-server >/dev/null 2>&1; then
    wget -qO /tmp/nats-server.tar.gz \
        "https://github.com/nats-io/nats-server/releases/download/${NATS_VERSION}/nats-server-${NATS_VERSION}-linux-${NARCH}.tar.gz"
    tar -xzf /tmp/nats-server.tar.gz -C /tmp
    sudo install -m 0755 "/tmp/nats-server-${NATS_VERSION}-linux-${NARCH}/nats-server" /usr/local/bin/nats-server
    rm -rf /tmp/nats-server.tar.gz "/tmp/nats-server-${NATS_VERSION}-linux-${NARCH}"
fi

sudo tee /etc/systemd/system/nats.service >/dev/null <<'UNIT'
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
sudo systemctl daemon-reload
sudo systemctl enable --now nats

for _ in $(seq 1 30); do
    if curl -sf http://localhost:8222/healthz >/dev/null 2>&1; then
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
