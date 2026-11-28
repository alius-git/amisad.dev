#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42297199-700a-4b3e-999e-018dc4b7df51
set -euo pipefail

# Update the release version and both publisher digests together.
NATS_VERSION=v2.15.1
NATS_SHA256_AMD64=bf5edc7b1ce98e885c368cb43a886eb148dc5d0551d99f3cf6141fb5e1954c70
NATS_SHA256_ARM64=e2fbab4cad7d3c76e3052eb959570393c9d73ba756b70bf8e9eea61e9ae6d49c
case "$(uname -m)" in
    aarch64) NATS_SHA256=$NATS_SHA256_ARM64 ;;
    *) NATS_SHA256=$NATS_SHA256_AMD64 ;;
esac

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
    echo 'The verified AmisAd provisioner is unavailable.' >&2
    exit 1
fi
exec "$provision" nats-install "$NATS_VERSION" "$NATS_SHA256"
