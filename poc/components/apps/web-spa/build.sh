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

npm install
npm run build
echo "web-spa build complete: dist/"
