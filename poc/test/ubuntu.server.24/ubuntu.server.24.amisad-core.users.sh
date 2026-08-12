#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - vm-core demo users: add the non-administrator persona accounts
# (maya, elena buyers/sellers; tom, priya operators; marcel, kai ad agency +
# creator - s005; pat delegate - s006; alex integration partner - s007; sam
# support - s008; dana analyst - s009; ingrid auditor - s010) and
# install the core->edge demo SSH keypair for the admin so scenario scripts
# can scp/ssh slice-runtime to the edge VMs. Passwords are set by a separate
# sensitive sshExec sequence step (vault-rendered, masked), never passed to
# this script. Runs as the admin (passwordless sudo).
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_STATUS_SERVICE_IP:-}" ] || [ -z "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status service" >&2
    exit 2
fi

# --- REGION: https://yuruna.link/network#why-host-coordinates-are-re-read-per-use
# The coordinates above are read once, and this script then runs for minutes on
# a host whose DHCP lease moves under it. yuruna-host-locate.timer refreshes
# /etc/yuruna/host.env every 60s, so re-reading immediately before each fetch
# follows the host rather than freezing where it was at startup. A failed fetch
# additionally earns one forced refresh: the file can be up to a refresh
# interval behind the very move that broke the fetch, so retrying without it
# would just re-dial the address that already failed.
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

BASE="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}"

echo "== non-admin demo users (maya, elena, tom, priya, marcel, kai, pat, alex, sam, dana, ingrid) =="
for u in maya elena tom priya marcel kai pat alex sam dana ingrid; do
    if ! id -u "$u" >/dev/null 2>&1; then
        sudo adduser --disabled-password --gecos "" "$u"
    fi
done
# The accounts are NOT in sudoers; passwords come from the sensitive step.

echo "== core->edge demo SSH keypair for the admin =="
mkdir -p "$REAL_HOME/.ssh"
chmod 700 "$REAL_HOME/.ssh"
amisad_host_fetch "$REAL_HOME/.ssh/amisad-demo-key"     "handoff/amisad-demo-key"
amisad_host_fetch "$REAL_HOME/.ssh/amisad-demo-key.pub" "handoff/amisad-demo-key.pub"
chmod 600 "$REAL_HOME/.ssh/amisad-demo-key"
chmod 644 "$REAL_HOME/.ssh/amisad-demo-key.pub"
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.ssh"

echo "amisad vm-core demo users provisioned"
