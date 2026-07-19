<#PSScriptInfo
.VERSION 2026.07.19
.GUID 42a7f3c0-9b21-4d84-8e15-6f2c9a1d0b77
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab build runtime
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

# Lab helper: drive the two-VM POC as two ordered Test-Sequence runs, since the
# single-cycle runner would merge the same-guest top-levels onto one VM.
#   1. amisad.build compile  -> builds binaries, uploads to the stash service
#   2. amisad.core s001      -> downloads binaries from the stash, deploys, runs
# The core run is only started if the build run exits 0 (the stash artifact must
# exist first). Must run ELEVATED (Hyper-V). See poc/README.md.
param(
    [string]$YurunaRoot = 'c:\git\yuruna',
    [switch]$NoConfigGate
)
$ErrorActionPreference = 'Continue'
$ts = Join-Path $YurunaRoot 'test\Test-Sequence.ps1'
if (-not (Test-Path $ts)) { Write-Error "Test-Sequence.ps1 not found at $ts"; exit 1 }
$gate = @(); if ($NoConfigGate) { $gate = @('-NoConfigGate') }

Write-Output "===== [1/2] amisad.build compile (build + upload binaries to stash) $([DateTime]::Now.ToString('s')) ====="
& pwsh -NoProfile -ExecutionPolicy Bypass -File $ts `
    workload.guest.ubuntu.server.24.build.amisad.compile @gate
$buildExit = $LASTEXITCODE
Write-Output "===== amisad.build compile exited $buildExit ====="
if ($buildExit -ne 0) {
    Write-Error "Build run failed (exit $buildExit); NOT starting the core run (no binaries in the stash)."
    exit $buildExit
}

Write-Output "===== [2/2] amisad.core s001 (download binaries + deploy + run) $([DateTime]::Now.ToString('s')) ====="
& pwsh -NoProfile -ExecutionPolicy Bypass -File $ts `
    workload.guest.ubuntu.server.24.core.amisad.s001.fulfillment @gate
$coreExit = $LASTEXITCODE
Write-Output "===== amisad.core s001 exited $coreExit ====="

Write-Output "--- final VM inventory ---"
(Hyper-V\Get-VM | Select-Object Name, State | Format-Table -AutoSize | Out-String -Width 120) | Write-Output
exit $coreExit
