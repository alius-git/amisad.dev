#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 alius-git
# AmisAd POC - create the amisad database and load the skeleton schema. The
# schema is fetched from the host status server (fetch-and-execute's channel)
# into /tmp because the postgres user cannot read the login user's 0750 home.
# TODO: open listen_addresses/pg_hba for in-cluster pods when services move
# off in-memory state (mirror the text-to-sql db script).
set -euo pipefail

if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_HOST_IP:-}" ] || [ -z "${YURUNA_HOST_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status server" >&2
    exit 2
fi

# Self-sufficient PostgreSQL install (Ubuntu's default packages): the
# framework's pgdg-based script raced its own cluster re-init (cycle 248).
if ! command -v psql >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -y
    sudo apt-get install -y postgresql
fi
sudo systemctl enable --now postgresql
for _ in $(seq 1 30); do
    if sudo -u postgres pg_isready -q 2>/dev/null; then break; fi
    sleep 2
done
sudo -u postgres pg_isready

SCHEMA=/tmp/amisad-schema.sql
wget --no-proxy -qO "$SCHEMA" \
    "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-repo/project/poc/db/schema.sql?nocache=${RANDOM}"
chmod 644 "$SCHEMA"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='amisad'" | grep -q 1 || \
    sudo -u postgres createdb amisad
sudo -u postgres psql -v ON_ERROR_STOP=1 -d amisad -f "$SCHEMA"
rm -f "$SCHEMA"
echo "AmisAd database ready"
