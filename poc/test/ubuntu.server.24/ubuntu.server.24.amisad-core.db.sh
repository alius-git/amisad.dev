#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# See https://yuruna.link/42010605-0008
# --- REGION: Initialize environment
set -euo pipefail

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

# Fetched and verified first, before the install: a digest the host could not
# supply or a download that does not match is decided in seconds, and costs
# nothing to find out before PostgreSQL is installed. A private directory (mode
# 0700), not a loose file in /tmp: another local user could otherwise swap the
# schema between its digest check and psql reading it.
AMISAD_WORK=$(mktemp -d "${TMPDIR:-/tmp}/amisad-fetch.XXXXXX")
trap 'rm -rf -- "$AMISAD_WORK"' EXIT
SCHEMA="$AMISAD_WORK/amisad-schema.sql"
amisad_host_fetch "$SCHEMA" "yuruna-repo/project/poc/db/schema.sql?nocache=${RANDOM}"
amisad_verify_download "$SCHEMA" "${AMISAD_SCHEMA_SHA256:-}" \
    "the database schema (poc/db/schema.sql)" AMISAD_SCHEMA_SHA256 || exit 7

# Self-sufficient PostgreSQL install (Ubuntu's default packages): the
# framework's pgdg-based script raced its own cluster re-init.
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

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='amisad'" | grep -q 1 || \
    sudo -u postgres createdb amisad
# stdin, not -f <path>: the postgres user cannot open a file in the private
# directory, and the bytes read are the bytes that were verified.
sudo -u postgres psql -v ON_ERROR_STOP=1 -d amisad -f - < "$SCHEMA"
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
GRANT SELECT, INSERT, UPDATE ON seller.offers, seller.orders, seller.inventory TO amisad;
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
echo "AmisAd database ready (role amisad, pod access enabled)"
