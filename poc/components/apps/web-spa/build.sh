#!/bin/bash
# AmisAd web SPA - build wrapper invoked via `bazel run //components/apps/web-spa:build`.
set -euo pipefail
cd "$(dirname "$0")"

npm install
npm run build
echo "web-spa build complete: dist/"