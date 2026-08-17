<#PSScriptInfo
.VERSION 2026.08.19
.GUID 42d58154-8e5a-4811-9cf7-e4ed75eef83c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc build
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# AmisAd POC full build: doctor -> Bazel (Rust workspace) -> app wrappers.
# Bazel is the single entry point; the Flutter and Vite builds are `bazel run`
# targets because their toolchains fight Bazel sandboxing (see poc/README.md).
$ErrorActionPreference = 'Stop'
$poc = Split-Path -Parent $PSScriptRoot

& (Join-Path $PSScriptRoot 'doctor.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Push-Location $poc
try {
    $bazel = if (Get-Command bazelisk -ErrorAction SilentlyContinue) { 'bazelisk' } else { 'bazel' }

    & $bazel build //...
    if ($LASTEXITCODE -ne 0) { throw "bazel build //... failed" }

    & $bazel run //components/apps/web-spa:build
    if ($LASTEXITCODE -ne 0) { throw "web-spa build failed" }

    & $bazel run //components/apps/buyer-flutter:build
    if ($LASTEXITCODE -ne 0) { throw "buyer-flutter build failed" }

    Write-Information "build-all OK - Rust workspace, web-spa, and buyer-flutter built" -InformationAction Continue
}
finally {
    Pop-Location
}
