#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 4205cef9-61eb-4b15-b1da-abb05c09eb52
# See https://yuruna.link/42010605-00c1
set -euo pipefail

account_home=${HOME:-}
if [ "$EUID" -eq 0 ]; then
    account=${SUDO_USER:-root}
    IFS=: read -r _ _ account_uid _ _ account_home _ < <(getent -- passwd "$account") || account_home=''
    if [[ $account_uid == 0 || $account_home != /* ]]; then
        echo 'Run the AmisAd scenario as the guest administrator.' >&2
        exit 1
    fi
fi

cd "${account_home:?The guest administrator home is unavailable}/amisad.dev/poc"
export REAL_HOME="$account_home"
provision="$PWD/target/release/amisad-provision"
if [[ ! -f $provision || -L $provision || ! -x $provision ]]; then
    provision=/usr/local/bin/amisad-provision
fi
if [ ! -x "$provision" ]; then
    echo 'The AmisAd scenario provisioner is unavailable.' >&2
    exit 1
fi
if [ "$EUID" -eq 0 ]; then
    exec runuser -u "$account" -- "$provision" scenario-run inventory
fi
exec "$provision" scenario-run inventory
