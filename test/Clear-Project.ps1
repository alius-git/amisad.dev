<#PSScriptInfo
.VERSION 2026.07.25
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
    Tear down the AmisAd POC lab to a known-clean host: remove every lab VM
    (and its storage), then sweep orphaned VM files. Runs on any Yuruna host
    type (Hyper-V, KVM, UTM).
.DESCRIPTION
    The teardown half of the end-to-end pass (Set-Resource.ps1 builds it back
    up). Steps, in order:

      1. Refuse to run if a Yuruna runner owns runner.pid -- it would race the
         live cycle's VMs.
      2. Close lab consoles that would steal GUI keystroke focus (Hyper-V only;
         see Stop-LabConsole).
      3. Remove every lab VM AND its storage: the known topology names, plus a
         prefix sweep for amisad-* / amisad.* / the configured test-VM prefix.
      4. Run the framework's Remove-OrphanedVMFiles.ps1 -Force to sweep files
         no longer tied to any registered VM.

    PORTABILITY. Every VM operation goes through the Yuruna host contract
    (Get-VMState / Stop-VMForce / Remove-VM from
    host/<host-type>/modules/Yuruna.Host.psm1, loaded by Initialize-AmisAdHost)
    rather than Hyper-V cmdlets, and the prefix sweep delegates to the
    framework's own host-neutral Remove-TestVMFiles.ps1. Nothing here branches
    on hypervisor.

    Elevation is required: removing VMs is privileged on every host.
.PARAMETER YurunaRoot
    Path to the Yuruna framework checkout that holds test/. Optional -- see
    Resolve-YurunaRoot for the discovery order (the runner's
    YURUNA_CONFIG_PATH makes it exact in-cycle).
.EXAMPLE
    pwsh test/Clear-Project.ps1
.EXAMPLE
    pwsh test/Clear-Project.ps1 -YurunaRoot /home/tester/git/yuruna
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

# The known demo topology, swept by exact name even if the prefix sweep misses
# a renamed-mid-chain remnant (amisad-core-k8s is the intermediate rename).
$TopologyVms = @('amisad-build', 'amisad-edge-a', 'amisad-edge-b', 'amisad-core', 'amisad-core-k8s')

# --- 1) Refuse to sweep VMs out from under an active Yuruna runner -----------
# Only when run standalone. Inside a runner cycle the orchestration invokes this
# as its teardown step (set-resource), so the runner IS expected to be live:
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

# --- 3a) Remove the known topology VMs by exact name -------------------------
$removed = 0
foreach ($vmName in ($TopologyVms | Sort-Object -Unique)) {
    if (Remove-LabVM -Name $vmName) { $removed++ }
}
Write-Information -MessageData "Lab teardown removed $removed topology VM(s)." -InformationAction Continue

# --- 3b) Prefix sweep for stragglers ----------------------------------------
# Remove-TestVMFiles.ps1 is the framework's own host-neutral sweep: it
# enumerates VMs by name prefix through the same driver contract and removes
# each with its files. Using it here means this project never needs its own
# per-hypervisor VM listing (the Hyper-V `Get-VM | Where-Object Name -like`
# that used to live here is exactly what broke on KVM). Best-effort: a sweep
# failure must not abort a teardown that has already done its main work.
$sweepScript = Join-Path $YurunaRoot 'test/Remove-TestVMFiles.ps1'
if (Test-Path -LiteralPath $sweepScript) {
    # -Prefix takes a list, so both lab prefixes go in one sweep and the
    # host is enumerated once instead of once per prefix. An explicit
    # -Prefix selects exactly what it names, so the configured test-VM
    # prefix still needs its own no-argument call below; letting the
    # framework read that keeps this from hard-coding 'test-'. Best-effort
    # throughout: a sweep failure must not abort a teardown that has
    # already removed the topology by name.
    $labPrefixes = @('amisad-', 'amisad.')
    if ($PSCmdlet.ShouldProcess("VMs named $($labPrefixes -join '*, ')*", 'Sweep')) {
        try {
            & $sweepScript -Prefix $labPrefixes -Quiet
        } catch {
            Write-Warning "Prefix sweep reported: $($_.Exception.Message)"
        }
    }
    if ($PSCmdlet.ShouldProcess('configured test-VM prefix', 'Sweep')) {
        try {
            & $sweepScript -Quiet
        } catch {
            Write-Warning "Configured-prefix sweep reported: $($_.Exception.Message)"
        }
    }
} else {
    Write-Warning "Remove-TestVMFiles.ps1 not found at '$sweepScript'; skipped the prefix sweep (topology VMs were still removed by name)."
}

# --- 4) Sweep orphaned VM files (host-neutral dispatcher; -Force skips prompt)
$removeScript = Join-Path $YurunaRoot 'test/Remove-OrphanedVMFiles.ps1'
if (-not (Test-Path -LiteralPath $removeScript)) {
    throw "Remove-OrphanedVMFiles.ps1 not found at '$removeScript' (set -YurunaRoot)."
}

$exitCode = 0
if ($PSCmdlet.ShouldProcess($removeScript, 'Sweep orphaned VM files (-Force)')) {
    # Child process isolates the framework script's own `exit`; elevation is
    # inherited from this (already elevated) session.
    pwsh -NoProfile -File $removeScript -Force
    $exitCode = $LASTEXITCODE
}

exit $exitCode
