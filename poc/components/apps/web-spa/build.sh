#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd web SPA - build wrapper invoked via `bazel run //components/apps/web-spa:build`.
set -euo pipefail
if [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    cd "$BUILD_WORKSPACE_DIRECTORY/components/apps/web-spa"
else
    cd "$(dirname "$0")"
fi

# Install exactly what package-lock.json records, and fail instead of rewriting
# it when package.json disagrees. Dependency lifecycle scripts stay off: they are
# the usual npm supply-chain vector, and the only package that declares one,
# fsevents, is optional, macOS-only and unused by `vite build`.
npm ci --ignore-scripts --no-audit --no-fund
npm run build
echo "web-spa build complete: dist/"
