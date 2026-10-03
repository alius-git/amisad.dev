#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# See https://yuruna.link/42010605-0007
# --- REGION: Initialize environment
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "== non-admin demo users (maya, elena, tom, priya, marcel, kai, pat, alex, sam, dana, ingrid) =="
for u in maya elena tom priya marcel kai pat alex sam dana ingrid; do
    if ! id -u "$u" >/dev/null 2>&1; then
        sudo adduser --disabled-password --gecos "" "$u"
    fi
done
# The accounts are NOT in sudoers; passwords come from the sensitive step.

echo "== core->edge demo SSH keypair for the admin (generated here; the private key never leaves this VM) =="
SSH_DIR="$REAL_HOME/.ssh"
DEMO_KEY="$SSH_DIR/amisad-demo-key"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
# A key that already parses with an empty passphrase stays: the edges may
# already authorize it. Anything else (absent, truncated, passphrase-protected)
# is replaced, together with its .pub.
if [ -f "$DEMO_KEY" ] && ssh-keygen -y -P '' -f "$DEMO_KEY" >/dev/null 2>&1; then
    echo "keeping the existing demo key"
else
    rm -f "$DEMO_KEY" "$DEMO_KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C 'amisad-demo' -f "$DEMO_KEY"
fi
# The .pub is always derived from the private key, so a stale or hand-edited
# copy cannot disagree with the key it is meant to describe. The comment field
# (amisad-demo) is what an edge's authorized_keys uses to replace this key
# instead of accumulating old ones.
ssh-keygen -y -P '' -f "$DEMO_KEY" > "$DEMO_KEY.pub"
chmod 600 "$DEMO_KEY"
chmod 644 "$DEMO_KEY.pub"
chown -R "$REAL_USER:$REAL_USER" "$SSH_DIR"
echo "demo key fingerprint: $(ssh-keygen -lf "$DEMO_KEY.pub")"

echo "amisad vm-core demo users provisioned"
