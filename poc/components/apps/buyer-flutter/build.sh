#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd buyer app - build wrapper invoked via `bazel run //components/apps/buyer-flutter:build`.
# Hydrates the Android platform scaffolding on first run, then builds a debug APK.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d android ]; then
    flutter create --platforms=android --project-name amisad_buyer .
fi
flutter pub get
flutter build apk --debug
echo "buyer-flutter build complete: build/app/outputs/flutter-apk/app-debug.apk"