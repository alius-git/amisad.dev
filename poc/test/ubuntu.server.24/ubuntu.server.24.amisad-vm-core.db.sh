#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - create the amisad database, load the schema, and open the
# instance to in-cluster pods: role 'amisad' (fixed lab password, rides in
# DATABASE_URL - see poc/test.md), listen_addresses '*', pg_hba for the pod
# and node networks. The role gets NO UPDATE/DELETE on ledger tables - the
# database itself enforces append-only. Schema is fetched from the host
# status server into /tmp because the postgres user cannot read the login
# user's 0750 home.
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

# App role 'amisad' (name also hardcoded in the grants and pg_hba below).
# ALTER runs unconditionally so a password change here lands on re-runs.
APP_PASSWORD=amisadpoc2026
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='amisad'" | grep -q 1 || \
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE amisad LOGIN"
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE amisad LOGIN PASSWORD '${APP_PASSWORD}'"
sudo -u postgres psql -v ON_ERROR_STOP=1 -d amisad <<'SQL'
GRANT USAGE ON SCHEMA ledger, seller TO amisad;
-- Ledgers: append-only for the app role; no UPDATE, no DELETE.
GRANT SELECT, INSERT ON ledger.consent_ledger, ledger.settlement_ledger, ledger.attestation_ledger TO amisad;
-- Instructions are working state: confirmed flips true once.
GRANT SELECT, INSERT, UPDATE ON ledger.settlement_instructions TO amisad;
GRANT SELECT, INSERT, UPDATE ON seller.offers, seller.orders TO amisad;
SQL

# Reachable from pods: listen on every interface, allow the pod/node networks.
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = '*'"
HBA=$(sudo -u postgres psql -tAc "SHOW hba_file")
if ! sudo grep -q amisad-pods "$HBA"; then
    printf 'host amisad amisad 10.0.0.0/8 scram-sha-256 # amisad-pods\nhost amisad amisad 192.168.0.0/16 scram-sha-256 # amisad-pods\n' | \
        sudo tee -a "$HBA" >/dev/null
fi
sudo systemctl restart postgresql
sudo -u postgres pg_isready
echo "AmisAd database ready (role ${APP_ROLE}, pod access enabled)"
