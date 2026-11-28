#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 4266ae95-bb37-4c94-9abc-528abc09316f
set -euo pipefail

# Preserve the fetched step identity while the installed provisioner owns
# all readiness observations and cluster commands.
provision=/usr/local/bin/amisad-provision
if [ -x "$provision" ]; then
    exec "$provision" core-ready
fi
account_home=${HOME:-}
if [ "$EUID" -eq 0 ]; then
    account=${SUDO_USER:-root}
    IFS=: read -r _ _ account_uid _ _ account_home _ < <(getent -- passwd "$account") || account_home=''
    if [ "$account_uid" = 0 ]; then
        account_home=''
    fi
fi
provision="$account_home/amisad.dev/poc/target/release/amisad-provision"
if [[ $account_home != /* || ! -f $provision || -L $provision || ! -x $provision ]]; then
    echo 'The AmisAd readiness provisioner is unavailable.' >&2
    exit 1
fi
if [ "$EUID" -eq 0 ]; then
    exec runuser -u "$account" -- "$provision" core-ready
fi
exec "$provision" core-ready
