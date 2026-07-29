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
if [ -z "${YURUNA_HOST_IP:-}" ] || [ -z "${YURUNA_HOST_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status service" >&2
    exit 2
fi
BASE="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}"

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
wget --no-proxy -qO "$REAL_HOME/.ssh/amisad-demo-key"     "${BASE}/handoff/amisad-demo-key"
wget --no-proxy -qO "$REAL_HOME/.ssh/amisad-demo-key.pub" "${BASE}/handoff/amisad-demo-key.pub"
chmod 600 "$REAL_HOME/.ssh/amisad-demo-key"
chmod 644 "$REAL_HOME/.ssh/amisad-demo-key.pub"
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.ssh"

echo "amisad vm-core demo users provisioned"
