<#PSScriptInfo
.VERSION 2026.11.26
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
    See https://yuruna.link/42010605-00b3.
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
. (Join-Path $PSScriptRoot 'AmisAd.LabWorkflow.ps1')
# Resolve-StashService lives in a module, not here: poc/build/run-tests.ps1 runs
# the same pre-flight, and the address a pass uploads its binaries to must not
# depend on which entry point started it.
Import-Module (Join-Path $PSScriptRoot 'AmisAd.StashService.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'AmisAd.Lab.psm1') -Force -DisableNameChecking

$YurunaRoot = Resolve-YurunaRoot -Explicit $YurunaRoot
$HostType   = Initialize-AmisAdHost -YurunaRoot $YurunaRoot
Write-Information "Warm-up on '$HostType' (framework: $YurunaRoot)."

# --- REGION: Validate host requirements
# Fail fast on a host that cannot drive its own hypervisor (Administrator on
# Hyper-V, virsh + /dev/kvm on KVM, utmctl + UTM.app on macOS). Without this
# gate the first provisioning stage burns its startup time before dying inside
# the hypervisor with a raw message that names the computer but not the fix.
if (-not (Test-HostRequirement -HostType $HostType)) { exit 1 }

$ts = Join-Path $YurunaRoot 'test/Debug-TestSequence.ps1'
if (-not (Test-Path -LiteralPath $ts)) { Write-Error "Debug-TestSequence.ps1 not found at $ts"; exit 1 }

# --- REGION: Resolve-StageLogDir
function Resolve-StageLogDir {
    <# See https://yuruna.link/42010605-00b2. #>
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

function Invoke-AmisAdNativeStageLogDir {
    [OutputType([string])]
    param([string]$YurunaRoot, [string]$Explicit)

    if (-not (Get-AmisAdVerifiedHostBinary -YurunaRoot $YurunaRoot)) { return }
    $argument = @{ TemporaryRoot = [IO.Path]::GetTempPath() }
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        $provider = $null
        $drive = $null
        try {
            $argument.ResolvedExplicit = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Explicit, [ref]$provider, [ref]$drive)
        } catch {
            Write-Verbose "Could not resolve the explicit native log directory: $($_.Exception.Message)"
            return
        }
        if ($provider.Name -cne 'FileSystem') { return }
        $argument.Explicit = $Explicit
    }
    $verb = 'amisad-lab-stage-log-dir'
    try {
        $reply = Invoke-VerifiedYurunaHostVerb -RepoRoot $YurunaRoot -Verb $verb -Argument $argument -TimeoutSeconds 30
    } catch {
        if ($_.Exception.Message -cne "host-binary-command-failed: $verb (unknown-verb)") { throw }
        return
    }
    if (-not $reply.Used) { return }
    $value = $reply.Value
    if ($value -isnot [Collections.IDictionary] -or $value['handled'] -isnot [bool]) {
        throw 'The native stage log directory reply is invalid.'
    }
    if (-not $value.handled) { return }
    if ($value['path'] -isnot [string] -or [string]::IsNullOrWhiteSpace($value.path) -or
        -not $value.Contains('error') -or ($null -ne $value.error -and $value.error -isnot [string])) {
        throw 'The native stage log directory reply is invalid.'
    }
    if ($value.error) { Write-Error "Could not prepare the stage log directory '$($value.path)'. $($value.error)" }
    return $value.path
}

$nativeLogDir = Invoke-AmisAdNativeStageLogDir -YurunaRoot $YurunaRoot -Explicit $LogDir
if ($nativeLogDir) { $LogDir = $nativeLogDir } else {
    $LogDir = Resolve-StageLogDir -Explicit $LogDir
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
}
$stageContext = @{ HostType = $HostType; SequenceScript = $ts; LogDir = $LogDir; NoProjectClone = $true }
Write-Information "Per-stage logs: $LogDir"

$warmup = Invoke-AmisAdWarmup -YurunaRoot $YurunaRoot -StageContext $stageContext -StashPin $StashServiceHost -NoConfigGate:$NoConfigGate
if ($warmup -ne 0) { exit $warmup }

Write-Information 'Warm-up complete. Live: amisad-core + amisad-edge-a + amisad-edge-b.'
exit 0
