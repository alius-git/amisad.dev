<#PSScriptInfo
.VERSION 2026.08.25
.GUID 428a3346-610c-4424-9401-45d9211a12c8
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
