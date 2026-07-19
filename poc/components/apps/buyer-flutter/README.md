# AmisAd buyer app (POC skeleton)

Flutter app, Android-first (side-loaded onto test devices). Source of truth is
`pubspec.yaml`, `lib/`, and `assets/`; the `android/` platform scaffolding is
hydrated by `build.sh` (`flutter create --platforms=android .`) on first build
and is intentionally not checked in.

Build: `bazel run //components/apps/buyer-flutter:build` (or `./build.sh`).
Output: `build/app/outputs/flutter-apk/app-debug.apk`, side-loadable via
`adb install`.

Brand assets come from `components/art/` (icon copied into `assets/`).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 alius-git
