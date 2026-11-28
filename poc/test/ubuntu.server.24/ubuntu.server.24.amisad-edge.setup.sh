#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42f32af5-d323-43ac-a15e-0cb36badcab5
# See https://yuruna.link/42010605-00c7
set -euo pipefail

artifact_plan=/etc/yuruna/amisad-artifacts.json
if [ ! -f "$artifact_plan" ] || [ -L "$artifact_plan" ]; then
    echo 'Invalid enrolled AmisAd artifact plan.' >&2
    exit 1
fi
artifact_root=/usr/local/lib/yuruna/amisad-artifacts
artifact_dir=$(sudo /usr/local/lib/yuruna/install-rust-artifacts --plan-file \
    "$artifact_plan" "$artifact_root" amisad-provision framework-revision) || exit 1
provision="$artifact_dir/amisad-provision"
if [ "${artifact_dir%/*}" != "$artifact_root" ] || ! [[ ${artifact_dir##*/} =~ ^[a-f0-9]{64}$ ]] ||
    [ ! -f "$provision" ] || [ -L "$provision" ] || [ ! -x "$provision" ]; then
    echo 'The verified AmisAd edge reporter is unavailable.' >&2
    exit 1
fi
exec sudo "$provision" edge-install-reporter
