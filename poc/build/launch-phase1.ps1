<#PSScriptInfo
.VERSION 2026.07.19
.GUID 42a7f3c0-9b21-4d84-8e15-6f2c9a1d0b77
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab build runtime
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

# Lab helper: drive the two-VM POC as ordered Test-Sequence runs, since the
# single-cycle runner would merge the same-guest top-levels onto one VM.
#   [1] amisad.build compile  -> builds binaries, uploads to the stash service
#   [2] amisad.core s001      -> downloads binaries from the stash, deploys, runs
# Each stage only starts if the previous exits 0. Must run ELEVATED (Hyper-V).
#
# State-aware so a re-run after a partial failure is safe (the core lineage is a
# two-tier snapshot chain amisad.k8s -> amisad.core, and s001 only probes the top
# tier):
#   - amisad.core present            -> skip build+deploy, run s001 warm.
#   - amisad.k8s present, core absent -> a prior run stranded the k8s tier;
#     rebuild the core tier explicitly (warm-paths off amisad.k8s) so s001 does
#     not cold-walk and collide on the k8s saveDiskSnapshot rename.
#   - neither present                -> clean cold: compile then s001 (which
#     cold-walks start.guest -> amisad.k8s -> amisad.core -> s001).
# See poc/README.md "Split build and runtime VMs".
param(
    [string]$YurunaRoot = 'c:\git\yuruna',
    [switch]$NoConfigGate
)
$ErrorActionPreference = 'Continue'
$ts = Join-Path $YurunaRoot 'test\Test-Sequence.ps1'
if (-not (Test-Path $ts)) { Write-Error "Test-Sequence.ps1 not found at $ts"; exit 1 }
$gate = @(); if ($NoConfigGate) { $gate = @('-NoConfigGate') }

function Invoke-Seq {
    param([string]$Name)
    Write-Output "===== Test-Sequence $Name  $([DateTime]::Now.ToString('s')) ====="
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $ts $Name @gate
    $code = $LASTEXITCODE
    Write-Output "===== $Name exited $code ====="
    return $code
}

$coreExists = [bool](Hyper-V\Get-VM -Name 'amisad.core' -ErrorAction SilentlyContinue)
$k8sExists  = [bool](Hyper-V\Get-VM -Name 'amisad.k8s'  -ErrorAction SilentlyContinue)

if ($coreExists) {
    Write-Output "amisad.core already present -- skipping build+deploy; running s001 warm."
} else {
    if ((Invoke-Seq 'workload.guest.ubuntu.server.24.build.amisad.compile') -ne 0) {
        Write-Error "Build run failed; NOT continuing (no binaries in the stash)."
        exit 1
    }
    if ($k8sExists) {
        Write-Output "amisad.k8s present without amisad.core (partial prior run) -- rebuilding the core tier."
        if ((Invoke-Seq 'workload.guest.ubuntu.server.24.core.amisad.baseline') -ne 0) {
            Write-Error "Core deploy recovery failed."
            exit 1
        }
    }
}

# Ensure only the core VM's console is active during first-login keystroke
# injection: stop the build VM and close stray vmconnect windows. A second
# live vmconnect (e.g. amisad.build left running after the compile) can steal
# GUI keystroke focus and corrupt the core VM's login (observed cold-test hang).
Hyper-V\Get-VM -Name 'amisad.build' -ErrorAction SilentlyContinue |
    Where-Object { $_.State -eq 'Running' } |
    ForEach-Object {
        Write-Output "Stopping $($_.Name) so its console does not steal keystroke focus."
        Hyper-V\Stop-VM -Name $_.Name -TurnOff -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
Get-Process vmconnect -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$coreExit = Invoke-Seq 'workload.guest.ubuntu.server.24.core.amisad.s001.fulfillment'

Write-Output "--- final VM inventory ---"
(Hyper-V\Get-VM | Select-Object Name, State | Format-Table -AutoSize | Out-String -Width 120) | Write-Output
exit $coreExit
