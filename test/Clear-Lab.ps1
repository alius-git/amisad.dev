<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42a3f7c9-5e21-4b8d-9c46-7f0a2d63e1b5
.AUTHOR Alisson Sol et al.
.Copyright (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab cleanup
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Tear down the AmisAd POC lab to a known-clean host: remove every amisad-*
    VM (and its storage), then sweep orphaned VM files. Runs on any Yuruna
    host type (Hyper-V, KVM, UTM).
.DESCRIPTION
    The teardown half of the end-to-end pass (Initialize-Lab.ps1 builds it back
    up). Steps, in order:

      1. Refuse to run if a Yuruna runner owns runner.pid -- it would race the
         live cycle's VMs.
      2. Close lab consoles that would steal GUI keystroke focus (Hyper-V only;
         see Stop-LabConsole).
      3. Hand the whole teardown to the framework's Remove-TestVMFiles.ps1
         with the lab's VM-name prefix.

    All VM removal lives in the framework: Remove-TestVMFiles.ps1 enumerates,
    force-stops and removes every VM whose name starts with the prefix, then
    runs the orphaned-file sweep, and it exits non-zero when anything
    survived. That single path is exercised by every project on every host
    type, so this project keeps no VM list and no removal logic of its own --
    a teardown bug gets fixed once, in the framework, for all of them.

    Elevation is required: removing VMs is privileged on every host.
.PARAMETER YurunaRoot
    Path to the Yuruna framework checkout that holds test/. Optional -- see
    Resolve-YurunaRoot for the discovery order (the runner's
    YURUNA_CONFIG_PATH makes it exact in-cycle).
.EXAMPLE
    pwsh test/Clear-Lab.ps1
.EXAMPLE
    pwsh test/Clear-Lab.ps1 -YurunaRoot /home/tester/git/yuruna
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [string]$YurunaRoot
)

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'AmisAd.HostCommon.ps1')

$YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
$HostType   = Initialize-AmisAdHost -YurunaRoot $YurunaRoot
Write-Information -MessageData "Lab teardown on '$HostType' (framework: $YurunaRoot)." -InformationAction Continue

# Every lab VM is named amisad-<role> (amisad-build, amisad-core,
# amisad-edge-a/b, and the amisad-core-k8s intermediate), so one prefix
# selects the whole topology -- including a remnant from a renamed or
# half-created VM that no hard-coded name list would know about.
$LabVmPrefix = 'amisad-'

# --- 1) Refuse to sweep VMs out from under an active Yuruna runner -----------
# Only when run standalone. Inside a runner cycle the orchestration invokes this
# as its teardown step (initialize-lab), so the runner IS expected to be live:
# $env:YURUNA_CYCLE_CONTEXT -- published by the orchestrator before each step and
# inherited by this child pwsh (its absence == standalone; see Get-CycleContext)
# -- marks that in-cycle invocation and skips the guard. Absent it, an operator
# ran this by hand and the guard still refuses to race an active cycle's VMs.
if (-not $env:YURUNA_CYCLE_CONTEXT) {
    $runnerPidFile = Join-Path $YurunaRoot 'test/status/runtime/runner.pid'
    if (Test-Path -LiteralPath $runnerPidFile) {
        $runnerPid = 0
        try { $runnerPid = [int]((Get-Content -LiteralPath $runnerPidFile -Raw).Trim()) } catch { $runnerPid = 0 }
        if ($runnerPid -gt 0 -and (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) {
            throw "A Yuruna runner (PID $runnerPid) is active; stop it before clearing the project."
        }
    }
}

# --- 2) Close lab consoles ---------------------------------------------------
Stop-LabConsole -HostType $HostType

# --- 3) Remove every lab VM, then the orphaned files it left behind ---------
# Remove-TestVMFiles.ps1 already force-stops and removes each matching VM
# through the host contract and finishes with the orphaned-file sweep, so
# this is the whole teardown. Its non-zero exit means a VM survived; that
# is propagated rather than swallowed, because the next stage would then be
# building on top of a stale VM whose disk no longer matches its definition.
$sweepScript = Join-Path $YurunaRoot 'test/Remove-TestVMFiles.ps1'
if (-not (Test-Path -LiteralPath $sweepScript)) {
    throw "Remove-TestVMFiles.ps1 not found at '$sweepScript' (set -YurunaRoot)."
}

$exitCode = 0
if ($PSCmdlet.ShouldProcess("VMs named $LabVmPrefix*", 'Stop, remove, and sweep files')) {
    # Child process isolates the framework script's own `exit`; elevation is
    # inherited from this (already elevated) session.
    pwsh -NoProfile -File $sweepScript -Prefix $LabVmPrefix
    $exitCode = $LASTEXITCODE
}

exit $exitCode
