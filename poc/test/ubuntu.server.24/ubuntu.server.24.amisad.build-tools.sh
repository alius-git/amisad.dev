#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 alius-git
# AmisAd POC - install the build toolchains on the build VM:
# rustup (pinned stable Rust), bazelisk (as /usr/local/bin/bazel), git, python3.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y git curl build-essential pkg-config python3

if ! command -v cargo >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain 1.83.0
fi
. "$HOME/.cargo/env"
cargo --version
rustc --version

if ! command -v bazel >/dev/null 2>&1; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) BARCH=amd64 ;;
        aarch64) BARCH=arm64 ;;
        *) BARCH=amd64 ;;
    esac
    sudo curl -fsSL -o /usr/local/bin/bazel \
        "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${BARCH}"
    sudo chmod +x /usr/local/bin/bazel
fi

echo "AmisAd build tools installed"
