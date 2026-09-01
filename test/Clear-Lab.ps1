<#PSScriptInfo
.VERSION 2026.09.01
.GUID 42daade2-e753-4aa3-a38e-967850d79682
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
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

<#
.SYNOPSIS
    Tear down the AmisAd POC lab to a known-clean host: remove every amisad-*
    VM (and its storage), then sweep orphaned VM files. Runs on any Yuruna
    host type (Hyper-V, KVM, UTM).
.DESCRIPTION
    The teardown half of the end-to-end pass (Initialize-Lab.ps1 builds it back
    up). Steps, in order:

      1. Assert this host can drive its own hypervisor at all (see PRIVILEGE
         below), so a missing right fails here with the fix rather than
         inside the first removal with the hypervisor's raw message.
      2. Refuse to run if a Yuruna runner owns runner.pid -- it would race the
         live cycle's VMs.
      3. Close lab consoles that would steal GUI keystroke focus (Hyper-V only;
         see Stop-LabConsole).
      4. Hand the whole teardown to the framework's Remove-TestVMFiles.ps1
         with the lab's VM-name prefix.

    All VM removal lives in the framework: Remove-TestVMFiles.ps1 enumerates,
    force-stops and removes every VM whose name starts with the prefix, then
    runs the orphaned-file sweep, and it exits non-zero when anything
    survived. That single path is exercised by every project on every host
    type, so this project keeps no VM list and no removal logic of its own --
    a teardown bug gets fixed once, in the framework, for all of them.

    PRIVILEGE is asserted at runtime against the DETECTED host rather than
    declared with '#requires -RunAsAdministrator': what removing a VM takes
    differs per host -- Administrator on Hyper-V, libvirt group membership on
    KVM, the invoking user's own utmctl session on UTM -- and a static
    requirement reads as "root" on Linux/macOS, which would refuse exactly the
    hosts this script claims to run on. Test-HostRequirement asks the host
    driver what applies and explains what is missing.
.PARAMETER YurunaRoot
    Path to the Yuruna framework checkout that holds test/. Optional -- see
    Resolve-YurunaRoot for the discovery order (the runner's
    YURUNA_CONFIG_PATH makes it exact in-cycle).
.EXAMPLE
    pwsh test/Clear-Lab.ps1
.EXAMPLE
    # Only needed for a checkout somewhere discovery would not look;
    # $HOME/git/yuruna is already the conventional fallback.
    pwsh test/Clear-Lab.ps1 -YurunaRoot /srv/lab/yuruna-checkout
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

# --- 1) This host can drive its own hypervisor ------------------------------
# Administrator on Hyper-V, virsh + /dev/kvm on KVM, utmctl + UTM.app on macOS.
# Without this gate the sweep dies inside the hypervisor with its own raw
# message, which names the computer but not the fix.
if (-not (Test-HostRequirement -HostType $HostType)) { exit 1 }

# Every lab VM is named amisad-<role> (amisad-build, amisad-core,
# amisad-edge-a/b, and the amisad-core-k8s intermediate), so one prefix
# selects the whole topology -- including a remnant from a renamed or
# half-created VM that no hard-coded name list would know about.
$LabVmPrefix = 'amisad-'

# --- 2) Refuse to sweep VMs out from under an active Yuruna runner -----------
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

# --- 3) Close lab consoles ---------------------------------------------------
Stop-LabConsole -HostType $HostType

# --- 4) Remove every lab VM, then the orphaned files it left behind ---------
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
