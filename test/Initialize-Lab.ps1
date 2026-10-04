<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42fa58fd-5d9d-4319-8816-8b5fe971bdbe
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2026 by Alisson Sol et al.
.TAGS amisad poc lab build warmup
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
    Build + start the AmisAd POC topology on a clean host (the "warm-up" half of
    the end-to-end pass; Clear-Lab.ps1 is the teardown half that runs first).
    Runs on any Yuruna host type (Hyper-V, KVM, UTM).
.DESCRIPTION
    See https://yuruna.link/42010605-0006.
.PARAMETER YurunaRoot
    Yuruna framework checkout that holds test/Debug-TestSequence.ps1. Optional --
    see Resolve-YurunaRoot for the discovery order.
.PARAMETER LogDir
    Per-stage Debug-TestSequence logs. Defaults to a folder inside the running
    cycle so the logs travel with the cycle's other artifacts, and to
    <temp>/amisad-tests when this runs outside a cycle.
.PARAMETER NoConfigGate
    Forwarded to each guest build (skip the pre-cycle Test-Config.ps1 gate).
.PARAMETER StashServiceHost
    Pins the stash service instead of discovering it. Empty (the default) runs
    the discovery order in Resolve-StashService; when neither a pin nor
    discovery produces an address that answers /healthz, the pass stops.
.EXAMPLE
    pwsh test/Initialize-Lab.ps1
#>

param(
    [string]$YurunaRoot,
    [string]$LogDir = '',
    [switch]$NoConfigGate,
    [string]$StashServiceHost = ''
)

$ErrorActionPreference = 'Continue'
# Progress goes to the information stream (displayed via InformationPreference),
# never the success stream -- Invoke-AmisAdStage returns an exit code the caller checks.
$InformationPreference = 'Continue'

. (Join-Path $PSScriptRoot 'AmisAd.HostCommon.ps1')
# Resolve-StashService lives in a module, not here: poc/build/run-tests.ps1 runs
# the same pre-flight, and the address a pass uploads its binaries to must not
# depend on which entry point started it.
Import-Module (Join-Path $PSScriptRoot 'AmisAd.StashService.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'AmisAd.Lab.psm1') -Force -DisableNameChecking

$YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
$HostType   = Initialize-AmisAdHost -YurunaRoot $YurunaRoot
Write-Information "Warm-up on '$HostType' (framework: $YurunaRoot)."

# Fail fast on a host that cannot drive its own hypervisor (Administrator on
# Hyper-V, virsh + /dev/kvm on KVM, utmctl + UTM.app on macOS). Without this
# gate the first provisioning stage burns its startup time before dying inside
# the hypervisor with a raw message that names the computer but not the fix.
if (-not (Test-HostRequirement -HostType $HostType)) { exit 1 }

$ts = Join-Path $YurunaRoot 'test/Debug-TestSequence.ps1'
if (-not (Test-Path -LiteralPath $ts)) { Write-Error "Debug-TestSequence.ps1 not found at $ts"; exit 1 }

# --- REGION: Resolve-StageLogDir
function Resolve-StageLogDir {
    <# See https://yuruna.link/42010605-0006. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_CYCLE_CONTEXT)) {
        try {
            $root = ($env:YURUNA_CYCLE_CONTEXT | ConvertFrom-Json -AsHashtable).rootCycleFolder
            # A cycle folder recorded but no longer on disk means the cycle is
            # over; writing it back would recreate a folder nothing collects.
            if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
                return (Join-Path $root 'initialize-lab.stage-logs')
            }
        } catch {
            Write-Verbose "Resolve-StageLogDir: unreadable cycle context, falling back to temp: $($_.Exception.Message)"
        }
    }
    return (Join-Path ([IO.Path]::GetTempPath()) 'amisad-tests')
}

$LogDir = Resolve-StageLogDir -Explicit $LogDir
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stageContext = @{ HostType = $HostType; SequenceScript = $ts; LogDir = $LogDir; NoProjectClone = $true }
Write-Information "Per-stage logs: $LogDir"

# Opt-in virtual display for headless keystroke/OCR reliability on the cold
# provisioning chains (no-op unless YURUNA_VIRTUAL_DISPLAY is truthy). The host
# type is the DETECTED one -- hard-coding Hyper-V would leave KVM/UTM (headless
# servers, the likeliest to need it) without the virtual display.
Import-Module (Join-Path $YurunaRoot 'test/modules/Test.HostCondition.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
if (Get-Command Initialize-HostDisplay -ErrorAction SilentlyContinue) {
    Initialize-HostDisplay -HostType $HostType
}

# --- REGION: Remove legacy demo key
# The core->edge keypair is generated INSIDE vm-core and its private half never
# leaves it (stage [6] moves only the public half). A host that ran an older
# version of this lab holds a pair under test/status/handoff, which the status
# service serves to the whole LAN; it is deleted and said so.
foreach ($line in (Remove-LegacyDemoKey -YurunaRoot $YurunaRoot -Confirm:$false)) { Write-Warning $line }

# --- REGION: Resolve stash service
# A stash is a requirement of this pass, not an optimization, and the project
# states no address of its own to fall back to -- so "none found" stops here,
# where it costs seconds, rather than an hour later inside a guest chain.
$stash = Resolve-StashService -YurunaRoot $YurunaRoot -Pin $StashServiceHost
foreach ($line in $stash.Lines) { Write-Information $line }
if (-not $stash.Address) {
    Write-Error ("No stash service answered /healthz; the build has nowhere to upload binaries and vm-core has nowhere to fetch them - stopping before the provisioning stages. " +
        "Start one on this host (Start-StashServiceVM.ps1), join a pool that runs one, or pin an address with -StashServiceHost / `$env:YURUNA_STASH_SERVICE_HOST.")
    exit 1
}

# --- REGION: Build binaries
if ((Invoke-AmisAdStage @stageContext -Name 'amisad-build' -Sequence 'workload.guest.ubuntu.server.24.amisad-build.compile' -NoConfigGate:$NoConfigGate) -ne 0) {
    Write-Error "Build stage failed; no binaries in the stash - stopping."
    exit 1
}
try { $null = Stop-VMForce -VMName 'amisad-build' } catch { Write-Verbose "Stop-VMForce amisad-build: $($_.Exception.Message)" }
Remove-InstallMedia -Name 'amisad-build' -SnapshotId 'amisad-build' -HostType $HostType
Write-Information "amisad-build stopped (kept on disk)."

# --- REGION: Provision edges
foreach ($edge in 'amisad-edge-a', 'amisad-edge-b') {
    if ((Invoke-AmisAdStage @stageContext -Name $edge -Sequence "workload.guest.ubuntu.server.24.$edge.baseline" -NoConfigGate:$NoConfigGate) -ne 0) {
        Write-Error "$edge provisioning failed - stopping."
        exit 1
    }
    Set-EdgeMemory -Name $edge -HostType $HostType
    Remove-InstallMedia -Name $edge -SnapshotId $edge -HostType $HostType
}

# --- REGION: Deploy core
if ((Invoke-AmisAdStage @stageContext -Name 'amisad-core' -Sequence 'workload.guest.ubuntu.server.24.amisad-core.deploy' -NoConfigGate:$NoConfigGate) -ne 0) {
    Write-Error "amisad-core deploy failed - stopping."
    exit 1
}
Remove-InstallMedia -Name 'amisad-core' -SnapshotId 'amisad-core' -HostType $HostType

# --- REGION: Start edges and wait for addresses
# The scenarios resolve amisad-edge-a/-b from these boot-time reports; a stale
# file from a prior run must not count, so delete first and anchor freshness to
# THIS start. Only s004.failover needs region-B live; the rest ignore it.
Write-Information "Starting amisad-edge-a + amisad-edge-b."
$logRoot = if ($env:YURUNA_LOG_DIR) { $env:YURUNA_LOG_DIR } else { Join-Path $YurunaRoot 'test/status/log' }
$edges = 'amisad-edge-a', 'amisad-edge-b'
$edgeStartup = Start-AmisAdEdge -Name $edges -LogRoot $logRoot -Confirm:$false
foreach ($line in $edgeStartup.Lines) { Write-Information $line }
if (-not $edgeStartup.Ok) {
    $detail = ($edgeStartup.Missing | ForEach-Object { "$_ ($($edgeStartup.State[$_].Reason))" }) -join '; '
    Write-Error "Region edges are not live: $detail. Stopping before the scenarios; VMs are left as-is for debugging."
    exit 1
}

Write-Information "--- VM inventory ---"
foreach ($vm in @('amisad-core', 'amisad-edge-a', 'amisad-edge-b', 'amisad-build')) {
    Write-Information ("  {0,-16} {1}" -f $vm, (Get-VMState -VMName $vm))
}


# --- REGION: Authorize demo public key
# See https://yuruna.link/42010605-0006
$edgeAddress = $edgeStartup.Address
$keyHandoff = Sync-AmisAdDemoKey -YurunaRoot $YurunaRoot -CoreVm 'amisad-core' -EdgeVm $edges -EdgeAddress $edgeAddress -Confirm:$false
foreach ($line in $keyHandoff.Lines) { Write-Information $line }
if (-not $keyHandoff.Ok) {
    Write-Error "The edges do not trust vm-core's demo key: $($keyHandoff.Reason). Stopping the warm-up instead of handing the scenarios edges they cannot reach."
    exit 1
}

Write-Information "Warm-up complete. Live: amisad-core + $($edges -join ' + ')."
exit 0
