#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 alius-git
# AmisAd web SPA - build wrapper invoked via `bazel run //components/apps/web-spa:build`.
set -euo pipefail
cd "$(dirname "$0")"

npm install
npm run build
echo "web-spa build complete: dist/"