<#PSScriptInfo
.VERSION 2026.11.26
.GUID 422575f2-b59c-4bf6-92c5-a76bc5b529bb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab test automation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://amisad.com
#>

#requires -version 7

<#
.SYNOPSIS
    AmisAd POC test automation driver: builds the design topology and runs every
    scenario against a shared amisad-core (stages [0]-[5]; see poc/test.md).
    Runs on any Yuruna host type (Hyper-V, KVM, UTM).
.DESCRIPTION
    See https://yuruna.link/42010605-00b7.
.PARAMETER YurunaRoot
    Yuruna framework checkout that holds test/Debug-TestSequence.ps1. Optional
    -- see Resolve-YurunaRoot for the discovery order.
.PARAMETER LogDir
    Per-stage Debug-TestSequence logs. Default: <temp>/amisad-tests.
.PARAMETER NoConfigGate
    Forwarded to each stage (skip the pre-cycle Test-Config.ps1 gate).
.EXAMPLE
    pwsh poc/build/run-tests.ps1
#>

param(
    [string]$YurunaRoot,
    [string]$LogDir = (Join-Path ([IO.Path]::GetTempPath()) 'amisad-tests'),
    [switch]$NoConfigGate
)
$ErrorActionPreference = 'Continue'
# Progress goes to the information stream (displayed via InformationPreference),
# never the success stream -- Invoke-AmisAdStage returns an exit code the caller checks.
$InformationPreference = 'Continue'

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $ProjectRoot 'test/AmisAd.HostCommon.ps1')
. (Join-Path $ProjectRoot 'test/AmisAd.LabWorkflow.ps1')
# Resolve-StashService lives in a module, not here: test/Initialize-Lab.ps1 runs
# the same pre-flight, and the address a pass uploads its binaries to must not
# depend on which entry point started it.
Import-Module (Join-Path $ProjectRoot 'test/AmisAd.StashService.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'test/AmisAd.Lab.psm1') -Force -DisableNameChecking

$YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
$HostType   = Initialize-AmisAdHost -YurunaRoot $YurunaRoot
Write-Information "Test driver on '$HostType' (framework: $YurunaRoot)."

# --- REGION: Validate host requirements
# Fail fast on a host that cannot call its own VM cmdlets (Administrator on
# Hyper-V, virsh + /dev/kvm on KVM, utmctl + UTM.app on macOS). Without this gate
# the first sweep dies inside the hypervisor with its own raw message, which
# names the computer but not the fix.
if (-not (Test-HostRequirement -HostType $HostType)) { exit 1 }

$ts = Join-Path $YurunaRoot 'test/Debug-TestSequence.ps1'
if (-not (Test-Path -LiteralPath $ts)) { Write-Error "Debug-TestSequence.ps1 not found at $ts"; exit 1 }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stageContext = @{ HostType = $HostType; SequenceScript = $ts; LogDir = $LogDir }

# Ordered scenario registry: append here as scenarios are implemented (test.md).
$Scenarios = @(
    'workload.guest.ubuntu.server.24.amisad-core.s001.fulfillment'
    'workload.guest.ubuntu.server.24.amisad-core.s002.fitting'
    'workload.guest.ubuntu.server.24.amisad-core.s003.silence'
    'workload.guest.ubuntu.server.24.amisad-core.s004.failover'
    'workload.guest.ubuntu.server.24.amisad-core.s005.attribution'
    'workload.guest.ubuntu.server.24.amisad-core.s006.mandate'
    'workload.guest.ubuntu.server.24.amisad-core.s007.inventory'
    'workload.guest.ubuntu.server.24.amisad-core.s008.mediation'
    'workload.guest.ubuntu.server.24.amisad-core.s009.suppression'
    'workload.guest.ubuntu.server.24.amisad-core.s010.certification'
)

# Headless keystroke/OCR reliability for the cold provisioning chains: attach
# the opt-in virtual display the way the runner's cycle path does (no-op unless
# YURUNA_VIRTUAL_DISPLAY is truthy - see poc/test.md). The host type is the
# DETECTED one -- hard-coding Hyper-V would leave KVM/UTM (headless servers, the
# likeliest to need it) without the virtual display.
Import-Module (Join-Path $YurunaRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
if (Get-Command Initialize-HostDisplay -ErrorAction SilentlyContinue) {
    Initialize-HostDisplay -HostType $HostType
}

# --- REGION: Refuse concurrent runner
# Refuse to sweep VMs out from under an active Yuruna runner.
$runnerPidFile = Join-Path $YurunaRoot 'test/status/runtime/runner.pid'
if (Test-Path -LiteralPath $runnerPidFile) {
    $runnerPid = 0
    try { $runnerPid = [int]((Get-Content -LiteralPath $runnerPidFile -Raw).Trim()) } catch { $runnerPid = 0 }
    if ($runnerPid -gt 0 -and (Get-Process -Id $runnerPid -ErrorAction SilentlyContinue)) {
        Write-Error "A Yuruna runner (PID $runnerPid) is active; stop it before running the test driver."
        exit 1
    }
}

# --- REGION: Clean start
# See https://yuruna.link/42010605-00b6
Stop-LabConsole -HostType $HostType -YurunaRoot $YurunaRoot
$sweepScript = Join-Path $YurunaRoot 'test/Remove-TestVMFiles.ps1'
if (-not (Test-Path -LiteralPath $sweepScript)) {
    Write-Error "Remove-TestVMFiles.ps1 not found at '$sweepScript' (set -YurunaRoot)."
    exit 1
}
# Child process isolates the framework script's own `exit`.
$sweepExit = Invoke-AmisAdCleanup -SweepScript $sweepScript -Prefix @('amisad-', 'amisad.', 'test-') -LogDir $LogDir -YurunaRoot $YurunaRoot
if ($sweepExit -ne 0) {
    Write-Error "Clean-start sweep failed (exit $sweepExit); a lab VM survived - stopping before provisioning on top of it."
    exit 1
}
Stop-LabConsole -HostType $HostType -YurunaRoot $YurunaRoot

$warmup = Invoke-AmisAdWarmup -YurunaRoot $YurunaRoot -StageContext $stageContext -Driver -Scenarios $Scenarios -NoConfigGate:$NoConfigGate
if ($warmup -ne 0) { exit $warmup }

Write-Information "ALL SCENARIOS PASSED. Demo environment live: amisad-core + amisad-edge-a + amisad-edge-b."
Write-Information "--- final VM inventory ---"
foreach ($vm in @('amisad-core', 'amisad-edge-a', 'amisad-edge-b', 'amisad-build')) {
    Write-Information ("  {0,-16} {1}" -f $vm, (Get-VMState -VMName $vm))
}
exit 0
