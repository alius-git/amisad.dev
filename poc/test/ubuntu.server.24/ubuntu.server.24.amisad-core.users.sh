#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42cdea5e-5625-48dd-8d2b-9fef9861e44b
# See https://yuruna.link/42010605-00c5
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    account=${SUDO_USER:-}
    if [ -z "$account" ] || [ "$account" = root ]; then
        echo 'Run core provisioning as the guest administrator.' >&2
        exit 1
    fi
else
    account=$(id -un)
fi

IFS=: read -r _ _ account_uid _ _ account_home _ < <(getent -- passwd "$account") || account_home=''
provision="$account_home/amisad.dev/poc/target/release/amisad-provision"
if [[ $account_uid == 0 || $account_home != /* || ! -f $provision || -L $provision || ! -x $provision ]]; then
    echo 'The AmisAd core users provisioner is unavailable.' >&2
    exit 1
fi

# The deployed binary and SSH keys belong to the guest administrator.
if [ "$EUID" -eq 0 ]; then
    exec runuser -u "$account" -- "$provision" core-users
fi
exec "$provision" core-users
